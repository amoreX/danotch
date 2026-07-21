import { randomUUID } from 'node:crypto';
import type { Task } from '../types.js';

function storageKey(ownerId: string, taskId: string): string {
  return `${ownerId.length}:${ownerId}${taskId}`;
}

export class InMemoryTaskStore {
  private readonly tasks = new Map<string, Task>();

  get(ownerId: string, taskId: string): Task | undefined {
    return this.tasks.get(storageKey(ownerId, taskId));
  }

  list(ownerId: string): Task[] {
    return Array.from(this.tasks.values())
      .filter((task) => task.ownerId === ownerId)
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
  }

  createOrUpdate(ownerId: string, requestedId: string | undefined, message: string): Task {
    const id = requestedId || randomUUID();
    const key = storageKey(ownerId, id);
    let task = this.tasks.get(key);

    if (!task) {
      task = {
        id,
        ownerId,
        task: message,
        description: message.slice(0, 60),
        status: 'running',
        toolCallsCount: 0,
        streamingText: '',
        createdAt: new Date(),
        chatHistory: [],
      };
      Object.defineProperty(task, 'ownerId', {
        value: ownerId,
        enumerable: true,
        configurable: false,
        writable: false,
      });
      this.tasks.set(key, task);
    } else {
      task.status = 'running';
      task.streamingText = '';
    }

    return task;
  }
}
