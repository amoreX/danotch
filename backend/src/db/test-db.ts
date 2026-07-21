import { Client } from 'pg';

export const databaseUrl =
  process.env.DATABASE_URL ?? process.env.POSTGRES_URL ?? process.env.SUPABASE_DB_URL;

export async function withClient<T>(callback: (client: Client) => Promise<T>): Promise<T> {
  if (!databaseUrl) throw new Error('Database URL is unavailable');
  const client = new Client({
    connectionString: databaseUrl,
    ssl: databaseUrl.includes('localhost') ? false : { rejectUnauthorized: false },
  });
  await client.connect();
  try {
    return await callback(client);
  } finally {
    await client.end();
  }
}

export async function asUser<T>(
  client: Client,
  userId: string,
  callback: () => Promise<T>,
): Promise<T> {
  await client.query('begin');
  try {
    await client.query('set local role authenticated');
    await client.query(`select set_config('request.jwt.claim.sub', $1, true)`, [userId]);
    const result = await callback();
    await client.query('rollback');
    return result;
  } catch (error) {
    await client.query('rollback');
    throw error;
  }
}
