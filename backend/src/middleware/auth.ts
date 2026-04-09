import type { Request, Response, NextFunction } from 'express';
import { supabase } from '../lib/supabase.js';

interface AuthUser {
  sub: string;   // user_id (UUID)
  email: string;
  role: string;
}

// Extend Express Request to include user
declare global {
  namespace Express {
    interface Request {
      user?: AuthUser;
    }
  }
}

export function requireAuth(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    res.status(401).json({ error: 'Missing or invalid Authorization header' });
    return;
  }

  const token = header.slice(7);

  // Use Supabase admin to verify — works with both HS256 and ES256 tokens
  supabase.auth.getUser(token).then(({ data, error }) => {
    if (error || !data.user) {
      console.log(`[auth] Token verification failed: ${error?.message ?? 'no user'}`);
      res.status(401).json({ error: 'Invalid or expired token' });
      return;
    }
    req.user = {
      sub: data.user.id,
      email: data.user.email ?? '',
      role: data.user.role ?? 'authenticated',
    };
    next();
  });
}

// Lightweight extraction for optional auth (doesn't block on failure)
export async function extractUserId(header: string | undefined): Promise<string | undefined> {
  if (!header?.startsWith('Bearer ')) return undefined;
  const token = header.slice(7);
  try {
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data.user) return undefined;
    return data.user.id;
  } catch {
    return undefined;
  }
}
