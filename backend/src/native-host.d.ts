export {};

declare global {
  interface PerchNativeHost {
    readonly installationSecret: string;
    getCredential(credential: string): Promise<string | undefined>;
    setCredential(credential: string, value: string): Promise<void>;
    deleteCredential(credential: string): Promise<void>;
  }

  var __perchNativeHost: PerchNativeHost | undefined;
}
