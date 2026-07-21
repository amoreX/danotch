import type { SupabaseClient } from '@supabase/supabase-js';
import { getAdminDb } from '../lib/admin-db.js';
import { userDb } from '../lib/user-db.js';
import {
  DeviceError,
  type ConsumedDeviceTicket,
  type DeviceChallenge,
  type DeviceRecord,
  type DeviceStore,
  type GatewayTicketRecord,
} from './device-service.js';

type DatabaseDevice = {
  id: string;
  user_id: string;
  display_name: string;
  public_key: string;
  key_algorithm: 'P-256' | 'Ed25519';
  key_format: 'spki-pem';
  key_fingerprint: string;
  status: 'active' | 'revoked';
  current_fence: number;
  enrolled_at: string;
  revoked_at: string | null;
  replaced_by_device_id: string | null;
};

type DatabaseChallenge = {
  id: string;
  user_id: string;
  purpose: 'enrollment' | 'ticket';
  device_id: string | null;
  nonce: string;
  expires_at: string;
  consumed_at: string | null;
};

function mapDevice(row: DatabaseDevice): DeviceRecord {
  return {
    id: row.id,
    userId: row.user_id,
    displayName: row.display_name,
    publicKey: row.public_key,
    keyAlgorithm: row.key_algorithm,
    keyFormat: row.key_format,
    keyFingerprint: row.key_fingerprint,
    status: row.status,
    currentFence: Number(row.current_fence),
    enrolledAt: row.enrolled_at,
    revokedAt: row.revoked_at,
    replacedByDeviceId: row.replaced_by_device_id,
  };
}

function mapChallenge(row: DatabaseChallenge): DeviceChallenge {
  return {
    id: row.id,
    userId: row.user_id,
    purpose: row.purpose,
    deviceId: row.device_id,
    nonce: row.nonce,
    expiresAt: row.expires_at,
    consumedAt: row.consumed_at,
  };
}

function operationError(error: { message: string; code?: string } | null, fallback: string): never {
  const message = error?.message ?? fallback;
  if (/limit/i.test(message)) throw new DeviceError('device_limit_exceeded', 409, message);
  if (/duplicate|already enrolled|unique/i.test(message)) {
    throw new DeviceError('duplicate_device_key', 409, message);
  }
  if (/replacement/i.test(message)) throw new DeviceError('invalid_replacement', 409, message);
  if (/challenge|ticket|revoked|stale/i.test(message)) {
    throw new DeviceError('invalid_ticket', 401, message);
  }
  throw new Error(message);
}

export class SupabaseDeviceStore implements DeviceStore {
  constructor(private readonly fencing: SupabaseClient = getAdminDb('fencing')) {}

  async createChallenge(challenge: DeviceChallenge): Promise<void> {
    const { error } = await this.fencing.rpc('danotch_create_device_challenge', {
      p_id: challenge.id,
      p_user_id: challenge.userId,
      p_purpose: challenge.purpose,
      p_device_id: challenge.deviceId,
      p_nonce: challenge.nonce,
      p_expires_at: challenge.expiresAt,
    });
    if (error) operationError(error, 'Failed to create device challenge');
  }

  async getChallenge(userId: string, challengeId: string): Promise<DeviceChallenge | null> {
    const { data, error } = await this.fencing.rpc('danotch_get_device_challenge', {
      p_id: challengeId,
      p_user_id: userId,
    });
    if (error) operationError(error, 'Failed to read device challenge');
    return data ? mapChallenge(data as DatabaseChallenge) : null;
  }

  async enrollDevice(params: {
    challengeId: string;
    device: DeviceRecord;
    replacementDeviceId?: string;
    maxDevices: number;
    now: string;
  }): Promise<DeviceRecord> {
    const { data, error } = await this.fencing.rpc('danotch_enroll_device', {
      p_challenge_id: params.challengeId,
      p_device_id: params.device.id,
      p_user_id: params.device.userId,
      p_display_name: params.device.displayName,
      p_public_key: params.device.publicKey,
      p_key_algorithm: params.device.keyAlgorithm,
      p_key_fingerprint: params.device.keyFingerprint,
      p_replacement_device_id: params.replacementDeviceId ?? null,
      p_max_devices: params.maxDevices,
      p_now: params.now,
    });
    if (error || !data) operationError(error, 'Failed to enroll device');
    return mapDevice(data as DatabaseDevice);
  }

  async createTicket(params: {
    challengeId: string;
    ticket: GatewayTicketRecord;
    now: string;
  }): Promise<void> {
    const { error } = await this.fencing.rpc('danotch_create_gateway_ticket', {
      p_challenge_id: params.challengeId,
      p_ticket_hash: params.ticket.ticketHash,
      p_ticket_id: params.ticket.ticketId,
      p_user_id: params.ticket.userId,
      p_device_id: params.ticket.deviceId,
      p_protocol_version: params.ticket.protocolVersion,
      p_expires_at: params.ticket.expiresAt,
      p_now: params.now,
    });
    if (error) operationError(error, 'Failed to create gateway ticket');
  }

  async consumeTicket(params: {
    ticketHash: string;
    ticketId: string;
    userId: string;
    deviceId: string;
    protocolVersion: number;
    now: string;
  }): Promise<ConsumedDeviceTicket> {
    const { data, error } = await this.fencing.rpc('danotch_consume_gateway_ticket', {
      p_ticket_hash: params.ticketHash,
      p_ticket_id: params.ticketId,
      p_user_id: params.userId,
      p_device_id: params.deviceId,
      p_protocol_version: params.protocolVersion,
      p_now: params.now,
    });
    if (error || !data) operationError(error, 'Gateway ticket rejected');
    const raw = Array.isArray(data) ? data[0] : data;
    if (!raw) operationError(null, 'Gateway ticket rejected');
    const result = raw as {
      user_id: string;
      device_id: string;
      protocol_version: number;
      fence: number;
      ticket_id: string;
    };
    return {
      userId: result.user_id,
      deviceId: result.device_id,
      protocolVersion: Number(result.protocol_version),
      fence: Number(result.fence),
      ticketId: result.ticket_id,
    };
  }

  async getDevice(userId: string, deviceId: string): Promise<DeviceRecord | null> {
    const { data, error } = await this.fencing.rpc('danotch_get_active_device', {
      p_user_id: userId,
      p_device_id: deviceId,
    });
    if (error) operationError(error, 'Failed to read device');
    return data ? mapDevice(data as DatabaseDevice) : null;
  }

  async listDevices(userId: string): Promise<DeviceRecord[]> {
    const { data, error } = await userDb
      .from('danotch_devices')
      .select(
        'id,user_id,display_name,public_key,key_algorithm,key_format,key_fingerprint,status,current_fence,enrolled_at,revoked_at,replaced_by_device_id',
      )
      .eq('user_id', userId)
      .order('enrolled_at', { ascending: false });
    if (error) throw new Error(error.message);
    return ((data ?? []) as DatabaseDevice[]).map(mapDevice);
  }

  async revokeDevice(userId: string, deviceId: string, now: string): Promise<boolean> {
    const { data, error } = await this.fencing.rpc('danotch_revoke_device', {
      p_user_id: userId,
      p_device_id: deviceId,
      p_now: now,
    });
    if (error) operationError(error, 'Failed to revoke device');
    return Boolean(data);
  }

  async fenceUser(userId: string, now: string): Promise<void> {
    const { error } = await this.fencing.rpc('danotch_fence_user_devices', {
      p_user_id: userId,
      p_now: now,
    });
    if (error) operationError(error, 'Failed to fence account devices');
  }

  async fenceConnectionLogout(
    userId: string,
    deviceId: string,
    fence: number,
    now: string,
  ): Promise<boolean> {
    const { data, error } = await this.fencing.rpc('danotch_fence_connection_logout', {
      p_user_id: userId,
      p_device_id: deviceId,
      p_fence: fence,
      p_now: now,
    });
    if (error) operationError(error, 'Failed to fence device logout');
    return Boolean(data);
  }

  async assertCurrentFence(userId: string, deviceId: string, fence: number): Promise<boolean> {
    const { data, error } = await this.fencing.rpc('danotch_assert_device_fence', {
      p_user_id: userId,
      p_device_id: deviceId,
      p_fence: fence,
    });
    if (error) operationError(error, 'Failed to validate device fence');
    return Boolean(data);
  }
}
