import { type ReactNode } from 'react';

interface ButtonProps {
  children: ReactNode;
  onClick?: () => void;
  href?: string;
  size?: 'sm' | 'md' | 'lg' | 'xl';
  variant?: 'primary' | 'ghost';
  className?: string;
  external?: boolean;
}

const GRADIENT_IDLE   = 'linear-gradient(180deg, #9d8ff8 0%, #7b6af0 100%)';
const GRADIENT_HOVER  = 'linear-gradient(180deg, #b3a8fa 0%, #9080f5 100%)';

const SHADOW_IDLE = [
  'inset 0 1px 0 rgba(255,255,255,0.22)',
  'inset 0 -1.5px 0 rgba(0,0,0,0.18)',
  '0 0 0 1px rgba(90,74,180,0.55)',
  '0 2px 6px rgba(139,124,246,0.28)',
].join(', ');

const SHADOW_PRESSED = [
  'inset 0 2px 4px rgba(0,0,0,0.18)',
  'inset 0 0.5px 0 rgba(255,255,255,0.08)',
  '0 0 0 1px rgba(90,74,180,0.55)',
].join(', ');

const sizeMap: Record<string, string> = {
  sm: 'h-8 px-3.5 text-xs',
  md: 'h-9 px-4 text-sm',
  lg: 'h-10 px-6 text-sm',
  xl: 'h-12 px-7 text-base',
};

function hoverStart(e: React.MouseEvent<HTMLElement>) {
  e.currentTarget.style.background = GRADIENT_HOVER;
}

function hoverEnd(e: React.MouseEvent<HTMLElement>) {
  e.currentTarget.style.background = GRADIENT_IDLE;
}

function pressStart(e: React.MouseEvent<HTMLElement>) {
  const el = e.currentTarget;
  el.style.boxShadow = SHADOW_PRESSED;
  el.style.transform = 'scale(0.97)';
  el.style.background = GRADIENT_IDLE;
}

function pressEnd(e: React.MouseEvent<HTMLElement>) {
  const el = e.currentTarget;
  el.style.boxShadow = SHADOW_IDLE;
  el.style.transform = 'scale(1)';
  el.style.background = GRADIENT_IDLE;
}

// No transition — all state changes are instant
const sharedStyle: React.CSSProperties = {
  background: GRADIENT_IDLE,
  boxShadow: SHADOW_IDLE,
  transform: 'scale(1)',
  transition: 'none',
};

const baseClass =
  'inline-flex items-center justify-center gap-1.5 rounded-full font-semibold cursor-pointer select-none outline-none focus-visible:ring-2 focus-visible:ring-[#8B7CF6]/60 [&_svg]:-translate-y-px';

export default function Button({
  children,
  onClick,
  href,
  size = 'md',
  variant = 'primary',
  className = '',
  external = false,
}: ButtonProps) {
  const externalAttrs = external ? { target: '_blank', rel: 'noopener noreferrer' } : {};

  if (variant === 'ghost') {
    const cls = `${baseClass} ${sizeMap[size]} text-zinc-500 hover:text-zinc-900 hover:bg-zinc-100 ${className}`;
    return href ? (
      <a href={href} className={cls} {...externalAttrs}>{children}</a>
    ) : (
      <button onClick={onClick} className={cls}>{children}</button>
    );
  }

  const cls = `${baseClass} ${sizeMap[size]} text-white ${className}`;

  const handlers = {
    onMouseEnter: hoverStart,
    onMouseLeave: (e: React.MouseEvent<HTMLElement>) => { hoverEnd(e); pressEnd(e); },
    onMouseDown: pressStart,
    onMouseUp: (e: React.MouseEvent<HTMLElement>) => { pressEnd(e); hoverStart(e); },
  };

  if (href) {
    return (
      <a href={href} className={cls} style={sharedStyle} onClick={onClick} {...externalAttrs} {...handlers}>
        {children}
      </a>
    );
  }

  return (
    <button onClick={onClick} className={cls} style={sharedStyle} {...handlers}>
      {children}
    </button>
  );
}
