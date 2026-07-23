// Single source of truth for external Perch destinations. Every CTA and link
// consumes these so there is no place left to drift or leave a dead `#` href.
//
// Set VITE_DOWNLOAD_MANIFEST_URL once to the stable release pointer published
// by release-macos.yml. VITE_DOWNLOAD_URL remains an optional static fallback.
// Without either value the site renders a coming-soon state.
// Private source and issue URLs are intentionally absent (KTD9 / R20).
export const SITE = {
  // Populated from the build-time env when a notarized artifact has been
  // published to Vercel Blob. Undefined when no promoted artifact exists.
  downloadUrl: (import.meta.env.VITE_DOWNLOAD_URL as string | undefined) || undefined,
  downloadManifestUrl:
    (import.meta.env.VITE_DOWNLOAD_MANIFEST_URL as string | undefined) || undefined,

  // Public support and community destinations.
  supportEmail: 'support@perch.app',
  changelogUrl: '/changelog',
  securityArchitectureUrl: '/security',
  securityReportUrl: 'mailto:security@perch.app',
} as const;
