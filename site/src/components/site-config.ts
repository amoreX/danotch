// Single source of truth for external Perch destinations. Every CTA and link
// consumes these so there is no place left to drift or leave a dead `#` href.
//
// Set VITE_DOWNLOAD_URL at build time to enable the download CTA.
// Without it the site renders a coming-soon state and no artifact link is shown.
// Private source and issue URLs are intentionally absent (KTD9 / R20).
export const SITE = {
  // Populated from the build-time env when a notarized artifact has been
  // published to Vercel Blob. Undefined when no promoted artifact exists.
  downloadUrl: (import.meta.env.VITE_DOWNLOAD_URL as string | undefined) || undefined,

  // Public support and community destinations.
  supportEmail: 'support@perch.app',
  changelogUrl: '/changelog',
  securityArchitectureUrl: '/security',
  securityReportUrl: 'mailto:security@perch.app',
} as const;
