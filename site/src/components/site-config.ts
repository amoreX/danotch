// Single source of truth for external Perch destinations. Every CTA and link
// consumes these so there is no place left to drift or leave a dead `#` href.
export const SITE = {
  githubUrl: 'https://github.com/amoreX/perch',
  issuesUrl: 'https://github.com/amoreX/perch/issues',
  // Latest release page. Points at real Perch download artifacts once published;
  // until then it resolves to the repository's releases index (never a dead #).
  downloadUrl: 'https://github.com/amoreX/perch/releases/latest',
} as const;
