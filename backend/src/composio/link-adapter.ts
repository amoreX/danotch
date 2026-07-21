export interface ComposioLinkRequest {
  redirectUrl?: string | null;
  redirect_url?: string | null;
  waitForConnection(timeout?: number): Promise<unknown>;
}

export interface ComposioLinkClient {
  connectedAccounts: {
    link(
      userId: string,
      authConfigId: string,
      options: { callbackUrl: string },
    ): Promise<ComposioLinkRequest>;
  };
}

/**
 * Narrow adapter around the pinned @composio/core 0.6.10 link API. Tests inject
 * this interface so initiation can be contract-tested without network access
 * or a destructive connected-account fake.
 */
export async function createConnectionLink(
  client: ComposioLinkClient,
  userId: string,
  authConfigId: string,
  callbackUrl: string,
): Promise<ComposioLinkRequest> {
  return client.connectedAccounts.link(userId, authConfigId, { callbackUrl });
}
