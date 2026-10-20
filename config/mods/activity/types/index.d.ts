export type ActivityView = { frame: string; isFailed: boolean }

declare module 'claude-code' {
  interface PluginState {
    activity: { view: ActivityView }
  }
}
