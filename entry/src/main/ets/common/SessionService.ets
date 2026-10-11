/**
 * 播控中心（AVSession）与长时任务（BackgroundTasksKit）。
 * 创建 audio 类型媒体会话并激活，同步标题/歌手/播放状态到系统播控面板；
 * 接收系统 play/pause/playNext/playPrevious 指令回调（蓝牙耳机按键、播控中心、锻炼界面）。
 * startBackgroundRunning 需要 module.json5 声明 KEEP_BACKGROUND_RUNNING 权限，
 * 失败会自动重置标志以便下次重试。
 */

import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'FinTune';

export class SessionService {
  private static session: avSession.AVSession | null = null;
  private static bgStarted: boolean = false;
  private static ready: boolean = false;

/** 初始化（幂等，失败自动重置 ready 以便下次重试）：
   * 1) 创建 audio 类型 AVSession 并激活，注册 play/pause/playNext/playPrevious 指令回调
   *    （蓝牙耳机按键、播控中心、锁屏播控统一走这里）；
   * 2) 启动 AUDIO_PLAYBACK 长时任务（熄屏不被杀）。注意：必须声明
   *    ohos.permission.KEEP_BACKGROUND_RUNNING，否则报 201 Permission denied（后台被杀的根因） */
  static async init(ctx: common.UIAbilityContext, onPlay: () => void, onPause: () => void, onPlayNext: () => void,
    onPlayPrev: () => void): Promise<void> {
    if (SessionService.ready) {
      return;
    }
    SessionService.ready = true;
    try {
      const s: avSession.AVSession = await avSession.createAVSession(ctx, 'FinTune', 'audio');
      SessionService.session = s;
      s.on('play', (): void => {
        onPlay();
      });
      s.on('pause', (): void => {
        onPause();
      });
      s.on('playNext', (): void => {
        onPlayNext();
      });
      s.on('playPrevious', (): void => {
        onPlayPrev();
      });
      await s.activate();
    } catch (error) {
      SessionService.ready = false;
      hilog.warn(0x0001, TAG, 'create AVSession failed %{public}s', JSON.stringify(error));
    }
    try {
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [
          {
            // 用运行时包名，避免改包名后 wantAgent 指向旧 bundle 导致长时任务启动失败
            bundleName: ctx.applicationInfo.name,
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        ctx, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      SessionService.bgStarted = true;
    } catch (error) {
      SessionService.ready = false;
      hilog.warn(0x0001, TAG, 'start background running failed %{public}s', JSON.stringify(error));
    }
  }

/** 同步曲目元数据到播控中心（标题/歌手/时长） */
  static updateMetadata(id: string, title: string, artist: string, durationMs: number): void {
    const s: avSession.AVSession | null = SessionService.session;
    if (s === null) {
      return;
    }
    try {
      s.setAVMetadata({
        assetId: id,
        title: title,
        artist: artist,
        duration: durationMs
      });
    } catch (error) {
      hilog.warn(0x0001, TAG, 'setAVMetadata failed');
    }
  }

/** 同步播放状态到播控中心（播放中/已暂停） */
  static updateState(playing: boolean): void {
    const s: avSession.AVSession | null = SessionService.session;
    if (s === null) {
      return;
    }
    try {
      s.setAVPlaybackState({
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE
      });
    } catch (error) {
      hilog.warn(0x0001, TAG, 'setAVPlaybackState failed');
    }
  }
}
