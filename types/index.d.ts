export type Mood = 'idle' | 'working' | 'thinking' | 'looking' | 'happy'
export type ChatLine = { who: 'me' | 'buddy'; text: string }

declare module 'claude-code' {
  interface PluginState {
    buddy: {
      chat: Shaped<ChatLine[]>
      mood: Shaped<Mood>
      activity: Shaped<string>
      recent: Shaped<string[]>
      isReplying: Shaped<boolean>
    }
  }
}
