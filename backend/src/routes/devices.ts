import { Router, type RequestHandler } from 'express';
import {
  DeviceError,
  DeviceService,
  isUuid,
  publicDevice,
  type ChallengePurpose,
} from '../devices/device-service.js';
import { requestQuotaSubject, type QuotaStore } from '../security/quota-store.js';

interface DeviceRouteOptions {
  service: DeviceService;
  requireAuth: RequestHandler;
  freshAuthMaxAgeMs: number;
  now?: () => number;
  onDeviceInvalidated?: (identity: { userId: string; deviceId?: string }) => void;
  quota?: QuotaStore;
}

function handleError(error: unknown, res: Parameters<RequestHandler>[1]): void {
  if (error instanceof DeviceError) {
    res.status(error.status).json({ error: error.message, code: error.code });
    return;
  }
  console.error('[devices] request failed', error);
  res.status(500).json({ error: 'Device operation failed', code: 'device_operation_failed' });
}

export function createDeviceRoutes(options: DeviceRouteOptions): Router {
  const router = Router();
  const now = options.now ?? Date.now;

  router.use(options.requireAuth);

  router.post('/challenges', async (req, res) => {
    try {
      const purpose = req.body?.purpose as ChallengePurpose;
      if (purpose !== 'enrollment' && purpose !== 'ticket') {
        throw new DeviceError('invalid_purpose', 400, 'purpose must be enrollment or ticket');
      }
      if (
        purpose === 'enrollment'
        && (!req.user?.authTime || now() - req.user.authTime > options.freshAuthMaxAgeMs)
      ) {
        throw new DeviceError(
          'fresh_auth_required',
          401,
          'Fresh account authentication is required for device enrollment',
        );
      }
      const challenge = await options.service.createChallenge(
        req.user!.sub,
        purpose,
        req.body?.device_id,
      );
      res.status(201).json({
        challenge_id: challenge.id,
        purpose: challenge.purpose,
        device_id: challenge.deviceId,
        nonce: challenge.nonce,
        expires_at: challenge.expiresAt,
        signing_context: 'perch-device-challenge:1',
      });
    } catch (error) {
      handleError(error, res);
    }
  });

  router.post('/enroll', async (req, res) => {
    try {
      if (!req.user?.authTime || now() - req.user.authTime > options.freshAuthMaxAgeMs) {
        throw new DeviceError(
          'fresh_auth_required',
          401,
          'Fresh account authentication is required for device enrollment',
        );
      }
      if (!options.quota && process.env.NODE_ENV === 'production') {
        throw new Error('Enrollment quota store is required in production');
      }
      if (options.quota) {
        await options.quota.consume({
          capability: 'enrollment',
          subject: requestQuotaSubject({
            userId: req.user.sub,
          }),
        });
      }
      const device = await options.service.enroll({
        userId: req.user.sub,
        challengeId: req.body?.challenge_id,
        displayName: req.body?.display_name,
        publicKey: req.body?.public_key ?? {},
        signature: req.body?.signature,
        replacementDeviceId: req.body?.replacement_device_id,
      });
      if (typeof req.body?.replacement_device_id === 'string') {
        options.onDeviceInvalidated?.({
          userId: req.user.sub,
          deviceId: req.body.replacement_device_id,
        });
      }
      res.status(201).json({ device: publicDevice(device) });
    } catch (error) {
      handleError(error, res);
    }
  });

  router.get('/', async (req, res) => {
    try {
      const devices = await options.service.listDevices(req.user!.sub);
      res.json({ devices: devices.map(publicDevice) });
    } catch (error) {
      handleError(error, res);
    }
  });

  router.post('/:deviceId/tickets', async (req, res) => {
    try {
      const deviceId = req.params.deviceId as string;
      if (!isUuid(deviceId)) {
        throw new DeviceError('invalid_device_id', 400, 'deviceId must be a UUID');
      }
      const ticket = await options.service.issueTicket({
        userId: req.user!.sub,
        deviceId,
        challengeId: req.body?.challenge_id,
        signature: req.body?.signature,
        protocolVersions: req.body?.protocol_versions,
      });
      res.status(201).json({
        ticket: ticket.ticket,
        expires_at: ticket.expiresAt,
        protocol_version: ticket.protocolVersion,
        gateway_auth: {
          authorization: 'Bearer <ticket>',
          subprotocol_prefix: 'perch-ticket.',
          query_parameters_allowed: false,
        },
      });
    } catch (error) {
      handleError(error, res);
    }
  });

  router.delete('/:deviceId', async (req, res) => {
    try {
      const deviceId = req.params.deviceId as string;
      if (!isUuid(deviceId)) {
        throw new DeviceError('invalid_device_id', 400, 'deviceId must be a UUID');
      }
      await options.service.revokeDevice(req.user!.sub, deviceId);
      options.onDeviceInvalidated?.({ userId: req.user!.sub, deviceId });
      res.status(204).end();
    } catch (error) {
      handleError(error, res);
    }
  });

  router.post('/logout', async (req, res) => {
    try {
      await options.service.fenceUser(req.user!.sub);
      options.onDeviceInvalidated?.({ userId: req.user!.sub });
      res.status(204).end();
    } catch (error) {
      handleError(error, res);
    }
  });

  return router;
}
