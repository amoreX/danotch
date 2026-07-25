import { useState } from 'react';
import Button from './Button';
import { SITE } from './site-config';

const INSTALL_COMMAND = `git clone ${SITE.repositoryUrl}
cd perch
git checkout vX.Y.Z
git verify-tag vX.Y.Z
./install.sh`;

const ASSISTANT_PROMPT = `Install Perch from its canonical source repository at ${SITE.repositoryUrl}. Inspect docs/source-install.md and the checked-in install.sh first, choose the newest stable signed vX.Y.Z tag, verify it against docs/maintainer-keys.md, and run the repository's reviewed ./install.sh. Do not invent an install procedure and do not use curl | bash.`;

function AppleIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98l-.09.06c-.22.15-2.19 1.3-2.17 3.88.03 3.08 2.71 4.12 2.75 4.13-.05.13-.42 1.45-1.33 2.56M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z" />
    </svg>
  );
}

function CopyButton({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    await navigator.clipboard.writeText(value);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1800);
  };

  return (
    <button
      type="button"
      onClick={() => void copy()}
      className="rounded-full border border-white/20 px-5 py-3 font-mono text-sm text-white transition-colors hover:bg-white/10"
    >
      {copied ? 'Copied' : label}
    </button>
  );
}

export default function Download() {
  return (
    <section id="download" className="relative overflow-hidden border-t border-zinc-100 bg-[#111111]">
      <div
        aria-hidden="true"
        className="absolute inset-0 bg-cover bg-center"
        style={{ backgroundImage: 'url(/hero-image.jpg)' }}
      />
      <div aria-hidden="true" className="absolute inset-0 bg-black/65" />

      <div className="relative mx-auto max-w-[1280px] px-5 py-20 sm:px-8 md:py-32">
        <div className="max-w-3xl">
          <p className="mb-4 font-mono text-xs uppercase tracking-[0.18em] text-white/55">
            Signed source install
          </p>
          <h2 className="m-0 font-mono text-[clamp(34px,8vw,72px)] font-normal leading-tight tracking-[0.01em] text-white">
            Build Perch on your Mac.
          </h2>
          <p className="mt-6 max-w-2xl text-base leading-7 text-white/65">
            Clone the source, inspect the installer, and verify a signed stable tag. Perch supports
            macOS 26+ on Apple Silicon and bundles its checksum-pinned Node 24 runtime.
          </p>

          <pre className="mt-8 overflow-x-auto rounded-2xl border border-white/15 bg-black/55 p-5 text-sm leading-7 text-white/80">
            <code>{INSTALL_COMMAND}</code>
          </pre>

          <div className="mt-5 flex flex-col gap-3 sm:flex-row">
            <Button href={SITE.repositoryUrl} size="xl" external className="w-full sm:w-auto">
              <AppleIcon />
              View source
            </Button>
            <CopyButton value={INSTALL_COMMAND} label="Copy install commands" />
            <CopyButton value={ASSISTANT_PROMPT} label="Copy assistant prompt" />
          </div>

          <p className="mt-7 text-xs leading-6 text-white/45">
            No curl-to-shell path. Updates use verified annotated tags, staged builds, SQLite
            backups, and automatic rollback. Funding is not configured; Perch has no in-app
            donation prompt and donations never unlock features.
          </p>
        </div>
      </div>
    </section>
  );
}
