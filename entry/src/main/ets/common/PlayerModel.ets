/**
 * 全局播放模型（@Observed 单例）。
 * 封装 AVPlayer 生命周期（initialized -> prepare -> prepared -> play），
 * 播放队列 / 顺序·单曲循环·随机三种模式 / 上一首下一首 / 断网自动暂停恢复 /
 * 播放出错自动重试。对外通过 playerModel 单例共享状态，UI 侧用 @State 持有引用观察变化。
 */

import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CtxHolder } from './CtxHolder';
import { SessionService } from './SessionService';
import { NetBinder } from './NetBinder';
import { AppConfig } from './AppConfig';

const TAG: string = 'FinTune';

interface RawPlayPath {
  path?: string[];
}

export interface TrackInfo {
  id: string;
  name: string;
  artist: string;
  url: string;
  durationMs: number;
}

export const PLAY_MODES: string[] = ['sequence', 'repeat', 'shuffle'];
export const PLAY_MODE_LABELS: string[] = ['顺序', '单曲', '随机'];

@Observed
export class PlayerModel {
  trackName: string = '';
  artistName: string = '';
  currentId: string = '';
  isPlaying: boolean = false;
  errorMsg: string = '';
  positionMs: number = 0;
  durationMs: number = 0;
  mode: string = 'sequence';
  queue: TrackInfo[] = [];
  index: number = -1;
  private avPlayer: media.AVPlayer | null = null;
  private ticker: number = -1;
  private chain: Promise<void> = Promise.resolve();
  private retryCount: number = 0;
  private netLostFlag: boolean = false;
  private errored: boolean = false;
  private playerState: media.AVPlayerState = 'idle';
  private lastPos: number = -1;
  private stallCount: number = 0;
  private lastGoodPos: number = 0;
  private playAfterSeekDone: boolean = false;

/** 播放入口：把切歌请求串进 Promise 链，保证快速连点时旧播放器一定先释放，不会多首同时播 */
  /**
   * 播放入口：把切歌请求串进 Promise 链，保证快速连点时旧播放器一定先释放，不会多首同时播。
   * resumeFrom > 0 表示断点续播（弱网重试/断网恢复时传入上次播放位置，避免从头播放导致进度与歌词全乱）。
   */
  requestPlay(tracks: TrackInfo[], index: number, resumeFrom: number = -1): void {
    if (index < 0 || index >= tracks.length) {
      return;
    }
    this.chain = this.chain.then((): Promise<void> => this.doPlay(tracks, index, resumeFrom)).catch((error: Error): void => {
      hilog.warn(0x0001, TAG, 'play chain error');
    });
  }

  /** 真正执行播放：释放旧实例 -> 创建 AVPlayer -> 注册状态机/错误/进度事件 -> 起进度轮询 -> 起流。
   * 状态机：initialized(设置url后) 必须显式 prepare()；prepared 里取时长并 play；completed 按模式自动连播。
   * 时长兜底：AVPlayer 对 Jellyfin 转码流返回的 duration 不可靠（实测出现过 134217400 的垃圾值），
   * 不合理时改用曲目自带的 durationMs（Jellyfin RunTimeTicks 换算）。 */
  private async doPlay(tracks: TrackInfo[], index: number, resumeFrom: number): Promise<void> {
    const t0: TrackInfo = tracks[index];
    // 起流前确保已绑定到最优网络（Wi-Fi 优先），避免恢复播放/冷启动路径从未绑网而走蓝牙代理；
    // 传流地址用于判断服务器是否在内网——公网服务器会跳过"带感叹号"的不可用 Wi-Fi
    await NetBinder.bindBest(t0.url);
    await this.releasePlayer();
    this.errorMsg = '';
    this.errored = false;
    // 队列 URL 是点歌时按当时码率/token 烘焙的；起流时按当前设置重写，
    // 菜单切码率或重新登录换 token 后无需重新点歌，下一首/自动重连即生效
    const bm: number = AppStorage.get<number>('maxBitrate') ?? 128000;
    const token: string = AppStorage.get<string>('accessToken') ?? '';
    let streamUrl: string = t0.url.replace(/maxStreamingBitrate=\d+/, `maxStreamingBitrate=${bm}`);
    if (token.length > 0) {
      // 重新登录会产生新 token，旧队列 URL 里的 api_key 会 401（服务端日志 "Invalid token"）
      streamUrl = streamUrl.replace(/api_key=[^&]+/, `api_key=${token}`);
    }
    // 转码格式按当前菜单设置重写。
    // aac：Jellyfin 的 AAC 合法封装是 m4a，且必须显式带 transcodingContainer，否则服务端把 AAC 装进 mp3 容器导致转码失败
    // raw（不转码）：去掉 audioCodec 并抬高价率上限，Jellyfin 直接播放原始文件（FLAC 源即播 FLAC）
    const codec: string = AppStorage.get<string>('audioCodec') ?? 'mp3';
    if (codec === 'aac') {
      streamUrl = streamUrl.replace(/audioCodec=\w+/, 'audioCodec=aac');
      streamUrl = streamUrl.replace(/container=[^&]+/, 'container=m4a');
      streamUrl = `${streamUrl}&transcodingContainer=m4a`;
    } else if (codec === 'raw') {
      streamUrl = streamUrl.replace(/&audioCodec=\w+/, '');
      streamUrl = streamUrl.replace(/container=[^&]+/, 'container=flac%2Cmp3%2Cm4a%2Caac');
      streamUrl = streamUrl.replace(/maxStreamingBitrate=\d+/, 'maxStreamingBitrate=99999999');
    } else {
      streamUrl = streamUrl.replace(/audioCodec=\w+/, 'audioCodec=mp3');
      streamUrl = streamUrl.replace(/container=[^&]+/, 'container=mp3');
    }
    const t: TrackInfo = tracks[index];
    const p: media.AVPlayer = await media.createAVPlayer();
    this.avPlayer = p;
/** 播放错误处理：断网引起的错误提示等待恢复；偶发网络错误自动重试最多 2 次（间隔 1.5s）；重试耗尽才报最终错误 */
    p.on('error', (error: BusinessError): void => {
      hilog.error(0x0001, TAG, 'AVPlayer error code=%{public}d msg=%{public}s', error.code, error.message);
      // 状态操作类错误（如起流窗口内 seek）：非播放故障，忽略以免误触发重试中断播放
      if (error.code === 5400102) {
        return;
      }
      this.isPlaying = false;
      this.errored = true;
      SessionService.updateState(false);
      // token 失效（服务端 401）：重试无意义，提示重新登录并通知首页跳登录页
      if (error.message.indexOf('401') >= 0) {
        this.retryCount = 0;
        this.errorMsg = '登录已失效，请重新登录';
        const n: number = AppStorage.get<number>('authExpired') ?? 0;
        AppStorage.setOrCreate('authExpired', n + 1);
        return;
      }
      if (this.netLostFlag) {
        this.errorMsg = '网络断开，恢复后自动继续';
        return;
      }
      if (this.retryCount < 2 && this.queue.length > 0 && this.index >= 0) {
        this.retryCount += 1;
        this.errorMsg = '网络波动，自动重试中…';
        // currentTime 异常时回退到最后有效进度，避免从头播放
        const resumePos: number = this.positionMs > 0 ? this.positionMs :
          (this.lastGoodPos > 0 ? this.lastGoodPos : -1);
        const t: number = setTimeout(() => {
          clearTimeout(t);
          if (this.retryCount >= 2) {
            // 最后一次重试前先降网兜底（Wi-Fi 不通时切蜂窝/默认网），避免死绑在不可用的 Wi-Fi 上
            NetBinder.bindFallback().then((): void => {
              this.requestPlay(this.queue, this.index, resumePos);
            });
          } else {
            this.requestPlay(this.queue, this.index, resumePos);
          }
        }, 1500);
      } else {
        this.errorMsg = '播放出错，请重试';
      }
    });
    p.on('stateChange', (state: media.AVPlayerState): void => {
      this.playerState = state;
      if (state === 'initialized') {
        p.prepare();
      } else if (state === 'prepared') {
        this.retryCount = 0;
        this.errored = false;
        this.errorMsg = '';
        this.stallCount = 0;
        this.lastPos = -1;
        this.lastGoodPos = resumeFrom > 0 ? resumeFrom : 0;
        let d: number = p.duration;
        if (d <= 0 || d > 600000) {
          d = t.durationMs;
        }
        this.durationMs = d;
        SessionService.updateMetadata(this.currentId, this.trackName, this.artistName, this.durationMs);
        // 断点续播：弱网重试/恢复时先 seek 回上次位置，等 seekDone 再 play——
        // play 抢在 seek 生效前会导致网络流从头播放（实测"卡回开头"的根因）
        if (resumeFrom > 0) {
          let target: number = resumeFrom;
          if (d > 3000 && target > d - 3000) {
            target = Math.max(0, d - 3000);
          }
          this.playAfterSeekDone = true;
          p.seek(target);
          this.positionMs = target;
          // 兜底：部分网络流不回调 seekDone，1s 后仍未播则直接播，避免卡死在 prepared
          const st: number = setTimeout(() => {
            clearTimeout(st);
            if (this.playAfterSeekDone) {
              this.playAfterSeekDone = false;
              p.play();
            }
          }, 1000);
        } else {
          p.play();
        }
      } else if (state === 'completed') {
        this.isPlaying = false;
        this.advance(true);
      }
    });
/** seek 完成回调：断点续播等 seek 落位后再开始播放 */
    p.on('seekDone', (): void => {
      if (this.playAfterSeekDone) {
        this.playAfterSeekDone = false;
        p.play();
      }
    });
/** 系统每约 100ms 上报一次播放进度；按 500ms 阈值节流后再写入 @Observed 字段，
     * 避免 10Hz 的状态通知触发全 UI 重渲染（手表功耗敏感） */
    p.on('timeUpdate', (t: number): void => {
      if (Math.abs(t - this.positionMs) >= 500) {
        this.positionMs = t;
      }
    });
    this.queue = tracks;
    this.index = index;
    this.persistNow();
    this.trackName = t.name;
    this.artistName = t.artist;
    this.currentId = t.id;
    this.positionMs = resumeFrom > 0 ? resumeFrom : 0;
    this.durationMs = 0;
    this.isPlaying = true;
    this.ticker = setInterval(() => {
      const cur: media.AVPlayer | null = this.avPlayer;
      if (cur !== null) {
        this.positionMs = cur.currentTime;
      }
      // currentTime 在卡顿/缓冲瞬间可能返回 -1，不能用作断点；记录已知的最大有效进度
      if (this.positionMs >= 0 && this.positionMs > this.lastGoodPos) {
        this.lastGoodPos = this.positionMs;
      }
      // 卡顿看门狗：处于播放状态且进度有效、连续 4 秒没前进（约 2 次轮询），
      // 说明流已停滞但错误事件还没上来——主动从最后有效位置断点重连，比干等 error 恢复快。
      // 注意：positionMs 为 -1（无效）时不计为卡顿，避免误重连
      if (this.isPlaying && this.trackName.length > 0 && this.positionMs >= 0) {
        if (this.positionMs === this.lastPos) {
          this.stallCount += 1;
          // 阈值 3（约 6 秒）：先给播放器缓冲自愈的机会，轻微卡顿不触发重连
          if (this.stallCount >= 3 && this.retryCount < 2 &&
            this.queue.length > 0 && this.index >= 0 && this.lastGoodPos > 0) {
            this.retryCount += 1;
            this.stallCount = 0;
            hilog.warn(0x0001, TAG, 'stall detected, reconnect from %{public}d', this.lastGoodPos);
            this.errorMsg = '网络波动，自动重试中…';
            this.requestPlay(this.queue, this.index, this.lastGoodPos);
          }
        } else {
          this.stallCount = 0;
        }
        this.lastPos = this.positionMs;
      }
    }, 2000);
    p.url = streamUrl;
/** 挂接网络断开/恢复回调：断网暂停并提示，恢复后自动续播当前曲目 */
    NetBinder.onLost = (): void => {
      this.netLostFlag = true;
      this.pauseOnly();
      this.errorMsg = '网络断开，恢复后自动继续';
    };
    NetBinder.onAvailable = (): void => {
      if (this.netLostFlag) {
        this.netLostFlag = false;
        this.errorMsg = '';
        if (this.trackName.length > 0 && this.queue.length > 0 && this.index >= 0) {
          // 断网恢复：从断开时的位置续播，而不是从头播放
          const resumePos: number = this.positionMs > 0 ? this.positionMs :
            (this.lastGoodPos > 0 ? this.lastGoodPos : -1);
          this.requestPlay(this.queue, this.index, resumePos);
        }
      }
    };
    const ctx = CtxHolder.ctx;
    if (ctx !== null) {
      SessionService.init(ctx, (): void => {
        playerModel.resume();
      }, (): void => {
        playerModel.pauseOnly();
      }, (): void => {
        playerModel.next();
      }, (): void => {
        playerModel.prev();
      }).then((): void => {
        SessionService.updateMetadata(t.id, t.name, t.artist, 0);
        SessionService.updateState(true);
      });
    }
  }

/** 立即持久化当前队列与下标：切歌/自动连播/弱网重连时都会走到，保证播放中退出应用也不丢状态。
   * path（浏览路径）保留已持久化的值，由浏览页负责维护。 */
  private persistNow(): void {
    const ctx = CtxHolder.ctx;
    if (ctx === null || this.queue.length === 0 || this.index < 0) {
      return;
    }
    AppConfig.loadPlayState(ctx).then((raw: string): void => {
      let path: string[] = [];
      if (raw.length > 0) {
        try {
          const st = JSON.parse(raw) as RawPlayPath;
          path = st.path ?? [];
        } catch (error) {
          path = [];
        }
      }
      const st: string = JSON.stringify({ path: path, queue: this.queue, index: this.index });
      AppConfig.savePlayState(ctx, st);
    });
  }

/** 一曲播完自动推进：单曲循环=重播；随机=换随机下标；顺序=到队尾则停（手动切歌允许回卷到头） */
  private advance(auto: boolean): void {
    if (this.queue.length === 0 || this.index < 0) {
      return;
    }
    if (this.mode === 'repeat') {
      this.replay();
      return;
    }
    if (this.mode === 'shuffle') {
      if (this.queue.length === 1) {
        this.replay();
        return;
      }
      let next: number = this.index;
      while (next === this.index) {
        next = Math.floor(Math.random() * this.queue.length);
      }
      this.requestPlay(this.queue, next);
      return;
    }
    const last: number = this.queue.length - 1;
    if (this.index < last) {
      this.requestPlay(this.queue, this.index + 1);
    } else if (!auto) {
      this.requestPlay(this.queue, 0);
    }
  }

/** 重播当前曲目（completed 状态下直接 play() 即从头播放） */
  private replay(): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    p.play();
    this.isPlaying = true;
    SessionService.updateState(true);
  }

/** 下一首：随机模式走随机推进，顺序模式到尾回卷 */
  next(): void {
    if (this.mode === 'shuffle') {
      this.advance(true);
      return;
    }
    if (this.queue.length === 0 || this.index < 0) {
      return;
    }
    if (this.index < this.queue.length - 1) {
      this.requestPlay(this.queue, this.index + 1);
    } else {
      this.requestPlay(this.queue, 0);
    }
  }

/** 上一首：播放超过 3 秒时先重播当前（符合常见播控习惯），否则退到上一首（首条回卷到队尾） */
  prev(): void {
    if (this.queue.length === 0 || this.index < 0) {
      return;
    }
    if (this.positionMs > 3000) {
      this.requestPlay(this.queue, this.index);
      return;
    }
    if (this.index > 0) {
      this.requestPlay(this.queue, this.index - 1);
    } else {
      this.requestPlay(this.queue, this.queue.length - 1);
    }
  }

/** 跳转到指定毫秒位置（歌词双击跳转用），同时同步本地进度。
   * 仅在 prepared/playing/paused/completed 状态允许 seek——M4A 转码起流慢，
   * 起流窗口内 seek 会触发 5400102（Operate Not Permit）错误事件并中断播放 */
  seekTo(ms: number): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    const s: media.AVPlayerState = this.playerState;
    if (s !== 'prepared' && s !== 'playing' && s !== 'paused' && s !== 'completed') {
      hilog.warn(0x0001, TAG, 'seekTo ignored in state %{public}s', s);
      return;
    }
    try {
      p.seek(ms);
      this.positionMs = ms;
    } catch (error) {
      hilog.warn(0x0001, TAG, 'seek failed');
    }
  }

/** 循环切换播放模式：顺序 -> 单曲循环 -> 随机 */
  cycleMode(): void {
    const i: number = PLAY_MODES.indexOf(this.mode);
    this.mode = PLAY_MODES[(i + 1) % PLAY_MODES.length];
  }

/** 当前模式的展示文案 */
  modeText(): string {
    const i: number = PLAY_MODES.indexOf(this.mode);
    return i >= 0 ? PLAY_MODE_LABELS[i] : '顺序';
  }

/** 冷启动恢复：不回放，仅恢复队列/下标/当前曲目信息，让播放条与列表标记回到上次状态；点播放时由 resume() 发起真正播放 */
  restore(queue: TrackInfo[], index: number): void {
    if (queue.length === 0 || index < 0 || index >= queue.length) {
      return;
    }
    this.queue = queue;
    this.index = index;
    const t: TrackInfo = queue[index];
    this.trackName = t.name;
    this.artistName = t.artist;
    this.currentId = t.id;
  }

/** 继续播放：播放器实例不在（被杀或冷启动恢复态）时，用已持久化的队列重新起播 */
  resume(): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null || this.errored) {
      // 实例不存在或已处于 error 态（error 态的 AVPlayer 不能复用），重新起流
      if (this.queue.length > 0 && this.index >= 0) {
        this.retryCount = 0;
        this.errored = false;
        const resumePos: number = this.lastGoodPos > 0 ? this.lastGoodPos : -1;
        this.requestPlay(this.queue, this.index, resumePos);
      }
      return;
    }
    if (!this.isPlaying) {
      p.play();
      this.isPlaying = true;
      SessionService.updateState(true);
    }
  }

/** 仅暂停（系统播控/断网时调用），同步播控中心状态 */
  pauseOnly(): void {
    const p: media.AVPlayer | null = this.avPlayer;
    if (p === null) {
      return;
    }
    if (this.isPlaying) {
      p.pause();
      this.isPlaying = false;
      SessionService.updateState(false);
    }
  }

/** 播放/暂停切换（UI 按钮用） */
  toggle(): void {
    if (this.isPlaying) {
      this.pauseOnly();
    } else {
      this.resume();
    }
  }

/** 停止并清空整个播放状态（队列、进度、曲目信息） */
  async stop(): Promise<void> {
    await this.releasePlayer();
    this.trackName = '';
    this.artistName = '';
    this.currentId = '';
    this.isPlaying = false;
    this.errorMsg = '';
    this.positionMs = 0;
    this.durationMs = 0;
    this.queue = [];
    this.index = -1;
    const ctx = CtxHolder.ctx;
    if (ctx !== null) {
      AppConfig.savePlayState(ctx, JSON.stringify({ path: [], queue: [], index: -1 }));
    }
    SessionService.updateState(false);
  }

/** 释放播放器：先清进度轮询，再 release AVPlayer 实例，异常静默（释放失败不影响后续播放） */
  private async releasePlayer(): Promise<void> {
    if (this.ticker >= 0) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
    const p: media.AVPlayer | null = this.avPlayer;
    this.avPlayer = null;
    if (p !== null) {
      try {
        await p.release();
      } catch (error) {
        hilog.warn(0x0001, TAG, 'release player failed');
      }
    }
  }
}

export const playerModel: PlayerModel = new PlayerModel();
