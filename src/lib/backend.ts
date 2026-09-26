import { clearOfflineState } from '@/features/sync/runtime';
import type { Backend } from '@/ports';
import { backendKind } from './env';

/**
 * Composition root: the only module that knows which adapter backs the ports. Adapters load
 * lazily, so a build only downloads the backend it actually runs on.
 */
export async function createBackend(): Promise<Backend> {
  const kind = backendKind();
  switch (kind) {
    case 'memory': {
      // The demo's data lives in this tab and starts empty on every reload, so what the device kept
      // locally goes with it: a queue, a cached catalog and a terminal registration of a shop that
      // no longer exists would otherwise be replayed into a new one.
      await clearOfflineState();
      const { createMemoryBackend } = await import('@/adapters/memory');
      return createMemoryBackend();
    }
    case 'rest': {
      const { createRestBackend } = await import('@/adapters/rest');
      return createRestBackend();
    }
  }
}
