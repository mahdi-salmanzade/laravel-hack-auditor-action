// Posts (or updates) a PR comment with the Hack Auditor security report.
// Used by actions/github-script inside the composite action.

module.exports = async ({ github, context, core }) => {
  const fs = require('fs');
  const path = require('path');

  const resultsPath = process.env.RESULTS_PATH
    || path.join(process.env.GITHUB_WORKSPACE, '.hack-auditor-results.json');

  if (!fs.existsSync(resultsPath) || fs.statSync(resultsPath).size === 0) {
    // No results file — likely no PHP files changed in this PR.
    // Still post a clean comment so the team sees the scan ran.
    const cleanBody = [
      '## \u2705 Hack Auditor Security Report',
      '',
      '**No PHP files changed** \u2014 nothing to scan.',
      '',
      '---',
      '<sub>\u{1F6E1}\uFE0F Scanned by <a href="https://github.com/mahdi-salmanzade/laravel-hack-auditor">Laravel Hack Auditor</a></sub>',
    ].join('\n');

    const MARKER = '<!-- hack-auditor-report -->';
    const fullBody = MARKER + '\n' + cleanBody;

    const { data: comments } = await github.rest.issues.listComments({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.issue.number,
    });

    const existing = comments.find(c => c.body && c.body.includes(MARKER));

    if (existing) {
      await github.rest.issues.updateComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        comment_id: existing.id,
        body: fullBody,
      });
    } else {
      await github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        body: fullBody,
      });
    }

    core.info('Posted clean scan comment (no PHP files changed).');
    return;
  }

  let results;
  try {
    results = JSON.parse(fs.readFileSync(resultsPath, 'utf8'));
  } catch (e) {
    core.warning(`Failed to parse scan results: ${e.message}`);
    return;
  }

  const { overall_score, counts, vulnerabilities, summary } = results;
  const hasFindings = vulnerabilities && vulnerabilities.length > 0;

  // ── Build the comment body ────────────────────────────────────────────
  const scoreIcon =
    overall_score >= 80 ? '\u{1F7E2}' :  // green circle
    overall_score >= 60 ? '\u{1F7E1}' :  // yellow circle
    overall_score >= 40 ? '\u{1F7E0}' :  // orange circle
                          '\u{1F534}';    // red circle

  let body;

  if (!hasFindings) {
    // ── Clean scan — positive feedback loop ──────────────────────────────
    body = [
      `## \u2705 Hack Auditor Security Report`,
      '',
      `**No vulnerabilities found** \u2014 Score: ${overall_score}/100`,
      '',
      summary ? `> ${summary}\n` : '',
      '---',
      '<sub>\u{1F6E1}\uFE0F Scanned by <a href="https://github.com/mahdi-salmanzade/laravel-hack-auditor">Laravel Hack Auditor</a></sub>',
    ].join('\n');
  } else {
    // ── Findings present ─────────────────────────────────────────────────
    const severityIcon = {
      critical: '\u{1F534} Critical',
      high:     '\u{1F7E0} High',
      medium:   '\u{1F7E1} Medium',
      low:      '\u26AA Low',
    };

    // Summary table
    let table = '| Severity | Type | File | Line |\n';
    table += '|----------|------|------|------|\n';

    for (const v of vulnerabilities) {
      const sev = severityIcon[v.severity] || v.severity_label;
      table += `| ${sev} | ${v.type_label} | \`${v.location}\` | L${v.line} |\n`;
    }

    // Expandable details for each finding
    let details = '';
    for (const v of vulnerabilities) {
      details += `<details>\n`;
      details += `<summary><strong>${v.type_label}</strong> (${v.severity_label}) \u2014 <code>${v.location}:${v.line}</code></summary>\n\n`;
      details += `**OWASP:** ${v.owasp}\n\n`;
      details += `${v.description}\n\n`;
      if (v.proof) {
        details += `**Evidence:**\n\`\`\`php\n${v.proof}\n\`\`\`\n\n`;
      }
      if (v.fix) {
        details += `**Suggested fix:**\n\`\`\`php\n${v.fix}\n\`\`\`\n\n`;
      }
      details += `</details>\n\n`;
    }

    body = [
      `## ${scoreIcon} Hack Auditor Security Report`,
      '',
      `**Score:** ${overall_score}/100 | ` +
        `**Findings:** ${counts.total} ` +
        `(${counts.critical} critical, ${counts.high} high, ${counts.medium} medium, ${counts.low} low)`,
      '',
      summary ? `> ${summary}\n` : '',
      table,
      '### Details',
      '',
      details,
      '---',
      '<sub>\u{1F6E1}\uFE0F Scanned by <a href="https://github.com/mahdi-salmanzade/laravel-hack-auditor">Laravel Hack Auditor</a></sub>',
    ].join('\n');
  }

  // ── Post or update the comment ────────────────────────────────────────
  const MARKER = '<!-- hack-auditor-report -->';
  const fullBody = MARKER + '\n' + body;

  const { data: comments } = await github.rest.issues.listComments({
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: context.issue.number,
  });

  const existing = comments.find(c => c.body && c.body.includes(MARKER));

  if (existing) {
    await github.rest.issues.updateComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      comment_id: existing.id,
      body: fullBody,
    });
    core.info(`Updated existing PR comment #${existing.id}`);
  } else {
    await github.rest.issues.createComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.issue.number,
      body: fullBody,
    });
    core.info('Posted new PR comment with security report.');
  }
};
