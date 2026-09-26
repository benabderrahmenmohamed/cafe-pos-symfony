import type { RealtimeListener, RealtimePort, RealtimeTopic } from '@/ports';

/**
 * The in-process stand-in for the database's publication: one emitter per backend, shared by every
 * client of it, so a waiter's add reaches the caisse and the kitchen without either polling.
 *
 * Listeners are told which topic changed and nothing else — never the row — because the screens
 * re-read the queries a topic covers. A missed or repeated event then costs a refetch, never a
 * wrong screen, which is what lets the memory and REST adapters differ in how they deliver it.
 */
export interface MemoryRealtime {
  /** Tells the listeners of `shopId` that `topic` changed. Every port write of that shop calls it. */
  readonly emit: (shopId: string, topic: RealtimeTopic) => void;
  /** The port each client hands to the app. */
  readonly port: RealtimePort;
}

interface Subscription {
  readonly shopId: string;
  readonly listener: RealtimeListener;
}

export function createMemoryRealtime(): MemoryRealtime {
  // One entry per subscription, so subscribing the same function twice needs two unsubscribes.
  const subscriptions = new Set<Subscription>();

  return {
    emit(shopId, topic) {
      for (const subscription of [...subscriptions]) {
        if (subscription.shopId !== shopId) {
          continue;
        }
        try {
          subscription.listener(topic);
        } catch (error) {
          // One broken screen must not undo the write that notified it, or silence the others.
          console.error('A realtime listener threw', error);
        }
      }
    },

    port: {
      subscribe(shopId, listener) {
        const subscription: Subscription = { shopId, listener };
        subscriptions.add(subscription);
        return () => {
          subscriptions.delete(subscription);
        };
      },
    },
  };
}
