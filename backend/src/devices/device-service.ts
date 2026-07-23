import {
  createHash,
  createPublicKey,
  randomBytes,
  randomUUID,
  verify,
  type KeyObject,
} from 'node:crypto';
import jwt from 'jsonwebtoken';

export const DEVICE_KEY_ALGORITHMS = ['P-256', 'Ed25519'] as const;
export type DeviceKeyAlgorithm = typeof DEVICE_KEY_ALGORITHMS[number];
export const DEVICE_KEY_FORMAT = 'spki-pem';

export type ChallengePurpose = 'enrollment' | 'ticket';
export type DeviceStatus = 'active' | 'revoked';

export interface DeviceRecord {
  id: string;
  userId: string;
  displayName: string;
  publicKey: string;
  keyAlgorithm: DeviceKeyAlgorithm;
  keyFormat: typeof DEVICE_KEY_FORMAT;
  keyFingerprint: string;
  status: DeviceStatus;
  currentFence: number;
  enrolledAt: string;
  revokedAt: string | null;
  replacedByDeviceId: string | null;
}

export interface DeviceChallenge {
  id: string;
  userId: string;
  purpose: ChallengePurpose;
  deviceId: string | null;
  nonce: string;
  expiresAt: string;
  consumedAt: string | null;
}

export interface GatewayTicketRecord {
  ticketHash: string;
  ticketId: string;
  userId: string;
  deviceId: string;
  protocolVersion: number;
  expiresAt: string;
  consumedAt: string | null;
}

export interface ConsumedDeviceTicket {
  userId: string;
  deviceId: string;
  protocolVersion: number;
  fence: number;
  ticketId: string;
}

export interface DeviceStore {
  createChallenge(challenge: DeviceChallenge): Promise<void>;
  getChallenge(userId: string, challengeId: string): Promise<DeviceChallenge | null>;
  enrollDevice(params: {
    challengeId: string;
    device: DeviceRecord;
    replacementDeviceId?: string;
    maxDevices: number;
    now: string;
  }): Promise<DeviceRecord>;
  createTicket(params: {
    challengeId: string;
    ticket: GatewayTicketRecord;
    now: string;
  }): Promise<void>;
  consumeTicket(params: {
    ticketHash: string;
    ticketId: string;
    userId: string;
    deviceId: string;
    protocolVersion: number;
    now: string;
  }): Promise<ConsumedDeviceTicket>;
  getDevice(userId: string, deviceId: string): Promise<DeviceRecord | null>;
  listDevices(userId: string): Promise<DeviceRecord[]>;
  revokeDevice(userId: string, deviceId: string, now: string): Promise<boolean>;
  fenceUser(userId: string, now: string): Promise<void>;
  fenceConnectionLogout(
    userId: string,
    deviceId: string,
    fence: number,
    now: string,
  ): Promise<boolean>;
  assertCurrentFence(userId: string, deviceId: string, fence: number): Promise<boolean>;
}

export class DeviceError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

function digest(value: string): string {
  return createHash('sha256').update(value).digest('hex');
}

function dateAt(milliseconds: number): string {
  return new Date(milliseconds).toISOString();
}

function requireChallenge(
  challenge: DeviceChallenge | undefined,
  params: {
    userId: string;
    purpose: ChallengePurpose;
    deviceId?: string;
    now: string;
  },
): DeviceChallenge {
  if (
    !challenge
    || challenge.userId !== params.userId
    || challenge.purpose !== params.purpose
    || challenge.deviceId !== (params.deviceId ?? null)
    || challenge.consumedAt !== null
    || challenge.expiresAt <= params.now
  ) {
    throw new DeviceError('invalid_challenge', 401, 'Challenge is invalid, expired, or already used');
  }
  return challenge;
}

export function deviceChallengeMessage(params: {
  purpose: ChallengePurpose;
  challengeId: string;
  nonce: string;
  userId: string;
  deviceId?: string;
}): string {
  return [
    'perch-device-challenge',
    '1',
    params.purpose,
    params.challengeId,
    params.nonce,
    params.userId,
    params.deviceId ?? 'new',
  ].join(':');
}

function validatedPublicKey(input: {
  algorithm: unknown;
  format: unknown;
  value: unknown;
}): { key: KeyObject; pem: string; fingerprint: string; algorithm: DeviceKeyAlgorithm } {
  const algorithm = input.algorithm;
  if (
    !DEVICE_KEY_ALGORITHMS.includes(algorithm as DeviceKeyAlgorithm)
    || input.format !== DEVICE_KEY_FORMAT
    || typeof input.value !== 'string'
    || input.value.length > 1_000
  ) {
    throw new DeviceError(
      'invalid_public_key',
      400,
      `public_key algorithm must be ${DEVICE_KEY_ALGORITHMS.join(' or ')} in ${DEVICE_KEY_FORMAT} format`,
    );
  }
  try {
    const key = createPublicKey({ key: input.value, format: 'pem', type: 'spki' });
    if (algorithm === 'Ed25519' && key.asymmetricKeyType !== 'ed25519') {
      throw new Error('algorithm confusion');
    }
    if (
      algorithm === 'P-256'
      && (
        key.asymmetricKeyType !== 'ec'
        || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1'
      )
    ) {
      throw new Error('algorithm confusion');
    }
    const der = key.export({ type: 'spki', format: 'der' });
    const pem = key.export({ type: 'spki', format: 'pem' }).toString();
    return {
      key,
      pem,
      fingerprint: createHash('sha256').update(der).digest('hex'),
      algorithm: algorithm as DeviceKeyAlgorithm,
    };
  } catch {
    throw new DeviceError('invalid_public_key', 400, `Invalid ${String(algorithm)} SPKI public key`);
  }
}

function verifyProof(
  key: KeyObject,
  algorithm: DeviceKeyAlgorithm,
  signature: unknown,
  message: string,
): void {
  if (typeof signature !== 'string' || signature.length > 256 || signature.length < 8) {
    throw new DeviceError('invalid_proof', 401, 'Device proof is invalid');
  }
  try {
    const bytes = Buffer.from(signature, 'base64url');
    const validLength = algorithm === 'Ed25519'
      ? bytes.length === 64
      : bytes.length >= 8 && bytes.length <= 80;
    const valid = validLength && verify(
      algorithm === 'Ed25519' ? null : 'sha256',
      Buffer.from(message),
      key,
      bytes,
    );
    if (!valid) {
      throw new Error('invalid signature');
    }
  } catch {
    throw new DeviceError('invalid_proof', 401, 'Device proof is invalid');
  }
}

export interface DeviceServiceOptions {
  signingSecret: string;
  issuer: string;
  audience: string;
  challengeTtlMs: number;
  ticketTtlMs: number;
  maxDevicesPerUser: number;
  supportedProtocolVersions: readonly number[];
  now?: () => number;
}

export class DeviceService {
  private readonly now: () => number;

  constructor(
    readonly store: DeviceStore,
    private readonly options: DeviceServiceOptions,
  ) {
    if (Buffer.byteLength(options.signingSecret) < 32) {
      throw new Error('Device ticket signing secret must be at least 32 bytes');
    }
    this.now = options.now ?? Date.now;
  }

  async createChallenge(
    userId: string,
    purpose: ChallengePurpose,
    deviceId?: string,
  ): Promise<DeviceChallenge> {
    if (purpose === 'ticket') {
      if (!deviceId) throw new DeviceError('device_required', 400, 'device_id is required');
      const device = await this.store.getDevice(userId, deviceId);
      if (!device || device.status !== 'active') {
        throw new DeviceError('device_not_found', 404, 'Active device not found');
      }
    } else if (deviceId) {
      throw new DeviceError('unexpected_device', 400, 'Enrollment challenges cannot name a device');
    }
    const issuedAt = this.now();
    const challenge: DeviceChallenge = {
      id: randomUUID(),
      userId,
      purpose,
      deviceId: deviceId ?? null,
      nonce: randomBytes(32).toString('base64url'),
      expiresAt: dateAt(issuedAt + this.options.challengeTtlMs),
      consumedAt: null,
    };
    await this.store.createChallenge(challenge);
    return challenge;
  }

  async enroll(params: {
    userId: string;
    challengeId: string;
    displayName: unknown;
    publicKey: { algorithm: unknown; format: unknown; value: unknown };
    signature: unknown;
    replacementDeviceId?: unknown;
  }): Promise<DeviceRecord> {
    if (
      typeof params.displayName !== 'string'
      || params.displayName.trim().length < 1
      || params.displayName.trim().length > 80
    ) {
      throw new DeviceError('invalid_display_name', 400, 'display_name must be 1-80 characters');
    }
    if (
      params.replacementDeviceId !== undefined
      && (typeof params.replacementDeviceId !== 'string' || !isUuid(params.replacementDeviceId))
    ) {
      throw new DeviceError('invalid_replacement', 400, 'replacement_device_id must be a UUID');
    }
    const now = dateAt(this.now());
    const challenge = requireChallenge(
      await this.store.getChallenge(params.userId, params.challengeId) ?? undefined,
      { userId: params.userId, purpose: 'enrollment', now },
    );
    const publicKey = validatedPublicKey(params.publicKey);
    verifyProof(
      publicKey.key,
      publicKey.algorithm,
      params.signature,
      deviceChallengeMessage({
        purpose: 'enrollment',
        challengeId: challenge.id,
        nonce: challenge.nonce,
        userId: params.userId,
      }),
    );
    const device: DeviceRecord = {
      id: randomUUID(),
      userId: params.userId,
      displayName: params.displayName.trim(),
      publicKey: publicKey.pem,
      keyAlgorithm: publicKey.algorithm,
      keyFormat: DEVICE_KEY_FORMAT,
      keyFingerprint: publicKey.fingerprint,
      status: 'active',
      currentFence: 0,
      enrolledAt: now,
      revokedAt: null,
      replacedByDeviceId: null,
    };
    return this.store.enrollDevice({
      challengeId: challenge.id,
      device,
      replacementDeviceId: params.replacementDeviceId as string | undefined,
      maxDevices: this.options.maxDevicesPerUser,
      now,
    });
  }

  async issueTicket(params: {
    userId: string;
    deviceId: string;
    challengeId: string;
    signature: unknown;
    protocolVersions: unknown;
  }): Promise<{ ticket: string; expiresAt: string; protocolVersion: number }> {
    const versions = Array.isArray(params.protocolVersions)
      ? params.protocolVersions.filter((value): value is number => Number.isSafeInteger(value))
      : [];
    const protocolVersion = [...this.options.supportedProtocolVersions]
      .sort((a, b) => b - a)
      .find((version) => versions.includes(version));
    if (protocolVersion === undefined) {
      throw new DeviceError('unsupported_protocol', 426, 'No supported device protocol version');
    }
    const nowMs = this.now();
    const now = dateAt(nowMs);
    const [challenge, device] = await Promise.all([
      this.store.getChallenge(params.userId, params.challengeId),
      this.store.getDevice(params.userId, params.deviceId),
    ]);
    requireChallenge(challenge ?? undefined, {
      userId: params.userId,
      purpose: 'ticket',
      deviceId: params.deviceId,
      now,
    });
    if (!device || device.status !== 'active') {
      throw new DeviceError('device_not_found', 404, 'Active device not found');
    }
    verifyProof(
      createPublicKey(device.publicKey),
      device.keyAlgorithm,
      params.signature,
      deviceChallengeMessage({
        purpose: 'ticket',
        challengeId: challenge!.id,
        nonce: challenge!.nonce,
        userId: params.userId,
        deviceId: params.deviceId,
      }),
    );
    const ticketId = randomUUID();
    const expiresAtMs = nowMs + this.options.ticketTtlMs;
    const payload = {
      sub: params.userId,
      device_id: params.deviceId,
      protocol_version: protocolVersion,
      jti: ticketId,
      iss: this.options.issuer,
      aud: this.options.audience,
      iat: Math.floor(nowMs / 1_000),
      exp: Math.floor(expiresAtMs / 1_000),
    };
    const ticket = jwt.sign(payload, this.options.signingSecret, {
      algorithm: 'HS256',
      noTimestamp: true,
    });
    await this.store.createTicket({
      challengeId: params.challengeId,
      ticket: {
        ticketHash: digest(ticket),
        ticketId,
        userId: params.userId,
        deviceId: params.deviceId,
        protocolVersion,
        expiresAt: dateAt(expiresAtMs),
        consumedAt: null,
      },
      now,
    });
    return { ticket, expiresAt: dateAt(expiresAtMs), protocolVersion };
  }

  async consumeTicket(ticket: string): Promise<ConsumedDeviceTicket> {
    if (!ticket || ticket.length > 4_096) {
      throw new DeviceError('invalid_ticket', 401, 'Gateway ticket is invalid');
    }
    let claims: jwt.JwtPayload;
    try {
      const verified = jwt.verify(ticket, this.options.signingSecret, {
        algorithms: ['HS256'],
        issuer: this.options.issuer,
        audience: this.options.audience,
        clockTimestamp: Math.floor(this.now() / 1_000),
      });
      if (typeof verified === 'string') throw new Error('invalid claims');
      claims = verified;
    } catch {
      throw new DeviceError('invalid_ticket', 401, 'Gateway ticket is invalid or expired');
    }
    if (
      typeof claims.sub !== 'string'
      || typeof claims.device_id !== 'string'
      || typeof claims.jti !== 'string'
      || !Number.isSafeInteger(claims.protocol_version)
      || !this.options.supportedProtocolVersions.includes(claims.protocol_version as number)
    ) {
      throw new DeviceError('invalid_ticket', 401, 'Gateway ticket claims are invalid');
    }
    return this.store.consumeTicket({
      ticketHash: digest(ticket),
      ticketId: claims.jti,
      userId: claims.sub,
      deviceId: claims.device_id as string,
      protocolVersion: claims.protocol_version as number,
      now: dateAt(this.now()),
    });
  }

  listDevices(userId: string) {
    return this.store.listDevices(userId);
  }

  async revokeDevice(userId: string, deviceId: string): Promise<void> {
    if (!await this.store.revokeDevice(userId, deviceId, dateAt(this.now()))) {
      throw new DeviceError('device_not_found', 404, 'Active device not found');
    }
  }

  fenceUser(userId: string): Promise<void> {
    return this.store.fenceUser(userId, dateAt(this.now()));
  }

  async fenceConnectionLogout(
    userId: string,
    deviceId: string,
    fence: number,
  ): Promise<void> {
    if (!await this.store.fenceConnectionLogout(userId, deviceId, fence, dateAt(this.now()))) {
      throw new DeviceError('stale_fence', 401, 'Device connection fence is stale');
    }
  }
}

export class InMemoryDeviceStore implements DeviceStore {
  private readonly challenges = new Map<string, DeviceChallenge>();
  private readonly devices = new Map<string, DeviceRecord>();
  private readonly tickets = new Map<string, GatewayTicketRecord>();

  constructor(private readonly now: () => number = Date.now) {}

  async createChallenge(challenge: DeviceChallenge): Promise<void> {
    this.challenges.set(challenge.id, { ...challenge });
  }

  async getChallenge(userId: string, challengeId: string): Promise<DeviceChallenge | null> {
    const value = this.challenges.get(challengeId);
    return value?.userId === userId ? { ...value } : null;
  }

  async enrollDevice(params: {
    challengeId: string;
    device: DeviceRecord;
    replacementDeviceId?: string;
    maxDevices: number;
    now: string;
  }): Promise<DeviceRecord> {
    const challenge = requireChallenge(this.challenges.get(params.challengeId), {
      userId: params.device.userId,
      purpose: 'enrollment',
      now: params.now,
    });
    if ([...this.devices.values()].some((device) => device.keyFingerprint === params.device.keyFingerprint)) {
      throw new DeviceError('duplicate_device_key', 409, 'Device key is already enrolled');
    }
    const active = [...this.devices.values()]
      .filter((device) => device.userId === params.device.userId && device.status === 'active');
    let replacement: DeviceRecord | undefined;
    if (params.replacementDeviceId) {
      replacement = this.devices.get(params.replacementDeviceId);
      if (!replacement || replacement.userId !== params.device.userId || replacement.status !== 'active') {
        throw new DeviceError('invalid_replacement', 409, 'Replacement device is not active for this account');
      }
    } else if (active.length >= params.maxDevices) {
      throw new DeviceError('device_limit_exceeded', 409, 'Active device limit reached');
    }
    challenge.consumedAt = params.now;
    if (replacement) {
      replacement.status = 'revoked';
      replacement.revokedAt = params.now;
      replacement.currentFence += 1;
      replacement.replacedByDeviceId = params.device.id;
    }
    this.devices.set(params.device.id, { ...params.device });
    return { ...params.device };
  }

  async createTicket(params: {
    challengeId: string;
    ticket: GatewayTicketRecord;
    now: string;
  }): Promise<void> {
    const challenge = requireChallenge(this.challenges.get(params.challengeId), {
      userId: params.ticket.userId,
      purpose: 'ticket',
      deviceId: params.ticket.deviceId,
      now: params.now,
    });
    const device = this.devices.get(params.ticket.deviceId);
    if (!device || device.userId !== params.ticket.userId || device.status !== 'active') {
      throw new DeviceError('device_revoked', 401, 'Device is no longer active');
    }
    challenge.consumedAt = params.now;
    this.tickets.set(params.ticket.ticketHash, { ...params.ticket });
  }

  async consumeTicket(params: {
    ticketHash: string;
    ticketId: string;
    userId: string;
    deviceId: string;
    protocolVersion: number;
    now: string;
  }): Promise<ConsumedDeviceTicket> {
    const ticket = this.tickets.get(params.ticketHash);
    const device = this.devices.get(params.deviceId);
    if (
      !ticket
      || ticket.ticketId !== params.ticketId
      || ticket.userId !== params.userId
      || ticket.deviceId !== params.deviceId
      || ticket.protocolVersion !== params.protocolVersion
      || ticket.consumedAt !== null
      || ticket.expiresAt <= params.now
      || !device
      || device.userId !== params.userId
      || device.status !== 'active'
    ) {
      throw new DeviceError('invalid_ticket', 401, 'Gateway ticket is invalid, stale, or already used');
    }
    ticket.consumedAt = params.now;
    device.currentFence += 1;
    return {
      userId: params.userId,
      deviceId: params.deviceId,
      protocolVersion: params.protocolVersion,
      fence: device.currentFence,
      ticketId: params.ticketId,
    };
  }

  async getDevice(userId: string, deviceId: string): Promise<DeviceRecord | null> {
    const device = this.devices.get(deviceId);
    return device?.userId === userId ? { ...device } : null;
  }

  async listDevices(userId: string): Promise<DeviceRecord[]> {
    return [...this.devices.values()]
      .filter((device) => device.userId === userId)
      .map((device) => ({ ...device }));
  }

  async revokeDevice(userId: string, deviceId: string, now: string): Promise<boolean> {
    const device = this.devices.get(deviceId);
    if (!device || device.userId !== userId || device.status !== 'active') return false;
    device.status = 'revoked';
    device.revokedAt = now;
    device.currentFence += 1;
    for (const ticket of this.tickets.values()) {
      if (ticket.userId === userId && ticket.deviceId === deviceId && !ticket.consumedAt) {
        ticket.consumedAt = now;
      }
    }
    return true;
  }

  async fenceUser(userId: string, now: string): Promise<void> {
    for (const device of this.devices.values()) {
      if (device.userId === userId) device.currentFence += 1;
    }
    for (const ticket of this.tickets.values()) {
      if (ticket.userId === userId && !ticket.consumedAt) ticket.consumedAt = now;
    }
  }

  async fenceConnectionLogout(
    userId: string,
    deviceId: string,
    fence: number,
    now: string,
  ): Promise<boolean> {
    if (!await this.assertCurrentFence(userId, deviceId, fence)) return false;
    await this.fenceUser(userId, now);
    return true;
  }

  async assertCurrentFence(userId: string, deviceId: string, fence: number): Promise<boolean> {
    const device = this.devices.get(deviceId);
    return device?.userId === userId
      && device.status === 'active'
      && device.currentFence === fence;
  }
}

export function publicDevice(device: DeviceRecord) {
  return {
    id: device.id,
    display_name: device.displayName,
    key_algorithm: device.keyAlgorithm,
    key_format: device.keyFormat,
    key_fingerprint: device.keyFingerprint,
    status: device.status,
    current_fence: device.currentFence,
    enrolled_at: device.enrolledAt,
    revoked_at: device.revokedAt,
    replaced_by_device_id: device.replacedByDeviceId,
  };
}

export function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}
