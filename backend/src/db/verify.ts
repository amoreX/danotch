import { config } from '../config.js';
import { openDatabase, verifyDatabase } from './database.js';

const db = openDatabase(config.databasePath);
try {
  verifyDatabase(db);
  console.log('Local SQLite schema and migration checksums verified');
} finally {
  db.close();
}
