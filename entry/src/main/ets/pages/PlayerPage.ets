/**
 * 播放详情路由页（name='player'）。
 * 封面+播放进度环（Circle 描边方案，AVPlayer duration 不可靠时用 Jellyfin RunTimeTicks 兜底）、
 * 嵌入封面的播放暂停键、左右切歌、模式切换、音量面板、播放列表弹层；
 * 表冠调音量（累积约30°一格，方向可调）；左滑进入歌词路由页。
 */
import { audio } from '@kit.AudioKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { playerModel, PlayerModel, TrackInfo } from '../common/PlayerModel';
import { buildAuthHeader } from '../common/JellyfinClient';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';

@Component
struct PlayerPage {
  @State player: PlayerModel = playerModel;
  @StorageProp('serverUrl') serverUrl: string = '';
  @StorageProp('accessToken') accessToken: string = '';
  @State playlistOpen: boolean = false;
  @State volumeOpen: boolean = false;
  @State volumeVal: number = 0;
  @State volumeMax: number = 15;
  @State ringPos: number = 0;
  @State ringDur: number = 1;
  @State coverFail: boolean = false;
  @State coverRetry: number = 0;
  @State coverPixelMap: image.PixelMap | null = null;
  private navStack: NavPathStack = new NavPathStack();
  private uiTicker: number = -1;
  private audioMgr: audio.AudioManager = audio.getAudioManager();
  private touchStartX: number = -1;
  private crownAccum: number = 0;
  private crownVol: number = -1;
  private crownMaxVol: number = 15;
  private volHideTimer: number = -1;
  private lastTrackId: string = '';
  private playlistScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.startUiTicker();
    this.audioMgr.getVolume(audio.AudioVolumeType.MEDIA).then((v: number): void => {
      this.crownVol = v;
    });
    this.audioMgr.getMaxVolume(audio.AudioVolumeType.MEDIA).then((m: number): void => {
      this.crownMaxVol = m;
    });
    this.retryFocus('playerPageRoot', [200, 600, 1200]);
  }

  aboutToDisappear(): void {
    this.stopUiTicker();
    if (this.volHideTimer >= 0) {
      clearTimeout(this.volHideTimer);
      this.volHideTimer = -1;
    }
  }

  private reqFocus(id: string): void {
    try {
      const ok: boolean = focusControl.requestFocus(id);
      hilog.info(0x0001, 'FinTune', 'reqFocus %{public}s -> %{public}s', id, `${ok}`);
    } catch (error) {
      hilog.warn(0x0001, 'FinTune', 'reqFocus %{public}s threw', id);
    }
  }

  private retryFocus(id: string, delays: number[]): void {
    for (const d of delays) {
      const t: number = setTimeout(() => {
        clearTimeout(t);
        this.reqFocus(id);
      }, d);
    }
  }

/** 详情页 UI 轮询（1s）：刷新进度环、检测切歌后重置封面重试计数与占位状态 */
  private startUiTicker(): void {
    this.stopUiTicker();
    this.uiTicker = setInterval(() => {
      this.ringPos = playerModel.positionMs;
      this.ringDur = playerModel.durationMs > 0 ? playerModel.durationMs : 1;
      if (playerModel.currentId !== this.lastTrackId) {
        this.lastTrackId = playerModel.currentId;
        this.coverFail = false;
        this.coverRetry = 0;
        this.coverPixelMap = null;
        this.loadCover();
      }
    }, 1000);
  }

  private stopUiTicker(): void {
    if (this.uiTicker >= 0) {
      clearInterval(this.uiTicker);
      this.uiTicker = -1;
    }
  }

/** 封面图地址（Jellyfin 专辑图接口）。Jellyfin 12 起 api_key 废弃，改走 http+Authorization 头下载为 PixelMap */
  private coverUrl(): string {
    if (this.player.currentId.length === 0) {
      return '';
    }
    return `${this.serverUrl}/Items/${this.player.currentId}/Images/Primary?maxWidth=300&quality=90`;
  }

/** 带认证头下载封面并转为 PixelMap（Image 组件无法携带自定义请求头，Jellyfin 12 起必须头认证）。
   * 切歌时由 uiTicker 触发；失败重试 2 次后显示占位图标 */
  private async loadCover(): Promise<void> {
    if (this.player.currentId.length === 0 || this.coverRetry >= 3) {
      if (this.coverRetry >= 3) {
        this.coverFail = true;
      }
      return;
    }
    const url: string = `${this.coverUrl()}&r=${this.coverRetry}`;
    try {
      const req: http.HttpRequest = http.createHttp();
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Authorization': buildAuthHeader(this.accessToken) },
        connectTimeout: 6000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        const buf: ArrayBuffer = resp.result as ArrayBuffer;
        const src: image.ImageSource = image.createImageSource(buf);
        const pm: image.PixelMap = await src.createPixelMap();
        this.coverPixelMap = pm;
      } else {
        this.coverRetry += 1;
      }
    } catch (error) {
      this.coverRetry += 1;
    }
  }

/** 进度环描边：用 Circle 的 strokeDashArray 画圆弧（Progress 组件参数不保证响应式更新，
   * 换成纯属性绑定后稳定）。圆周长按直径90估算 c=283；整体旋转 -90° 使起点在 12 点方向。
   * 进度 = positionMs / durationMs（durationMs 已在 prepared 时用 Jellyfin 时长兜底） */
  private ringDash(): number[] {
    const c: number = 283;
    let f: number = this.ringPos / this.ringDur;
    if (f < 0) {
      f = 0;
    }
    if (f > 1) {
      f = 1;
    }
    return [Math.max(0.5, c * f), c];
  }

  private modeIcon(): Resource {
    if (this.player.mode === 'repeat') {
      return $r('app.media.repeat_icon');
    }
    if (this.player.mode === 'shuffle') {
      return $r('app.media.shuffle_icon');
    }
    return $r('app.media.seq_icon');
  }

  private async openVolume(): Promise<void> {
    this.volumeOpen = true;
    try {
      this.volumeMax = await this.audioMgr.getMaxVolume(audio.AudioVolumeType.MEDIA);
      this.volumeVal = await this.audioMgr.getVolume(audio.AudioVolumeType.MEDIA);
    } catch (error) {
      this.volumeOpen = false;
    }
  }

  private setVolume(v: number): void {
    this.volumeVal = v;
    this.audioMgr.setVolume(audio.AudioVolumeType.MEDIA, Math.round(v));
  }

/** 表冠调音量一步：更新系统音量、同步音量条数值、弹出音量面板并重置 2s 自动隐藏计时 */
  private bumpVolume(delta: number): void {
    if (this.crownVol < 0) {
      return;
    }
    const nv: number = this.crownVol + delta;
    if (nv < 0 || nv > this.crownMaxVol) {
      return;
    }
    this.crownVol = nv;
    this.volumeVal = nv;
    this.volumeMax = this.crownMaxVol;
    this.audioMgr.setVolume(audio.AudioVolumeType.MEDIA, nv);
    this.volumeOpen = true;
    if (this.volHideTimer >= 0) {
      clearTimeout(this.volHideTimer);
    }
    this.volHideTimer = setTimeout(() => {
      clearTimeout(this.volHideTimer);
      this.volHideTimer = -1;
      this.volumeOpen = false;
    }, 2000);
  }

/** 打开播放列表并自动定位到正在播放的曲目（列表渲染后再滚动，避免首帧布局未完成定位失效） */
  private openPlaylist(): void {
    this.playlistOpen = true;
    const t: number = setTimeout(() => {
      clearTimeout(t);
      if (playerModel.index >= 0) {
        this.playlistScroller.scrollToIndex(playerModel.index, true);
      }
    }, 100);
  }

  @Builder
  private playlistView() {
    Column({ space: 6 }) {
      Text(`播放列表（${this.player.queue.length}）`)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      List({ scroller: this.playlistScroller }) {
        ForEach(this.player.queue, (t: TrackInfo, idx: number) => {
          ListItem() {
            Column({ space: 2 }) {
              Text(t.name)
                .fontSize(13)
                .fontWeight(idx === this.player.index ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(idx === this.player.index ? '#FF3EB575' : '#FFFFFFFF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (t.artist.length > 0) {
                Text(t.artist)
                  .fontSize(10)
                  .opacity(0.5)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.playlistOpen = false;
              playerModel.requestPlay(this.player.queue, idx);
            })
          }
        }, (t: TrackInfo) => t.id)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 34, right: 34, top: 26, bottom: 30 })
    .backgroundColor('#E6000000')
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  @Builder
  private volumePanel() {
    Row({ space: 8 }) {
      Image($r('app.media.minus_icon'))
        .width(18)
        .height(18)
        .onClick(() => {
          if (this.volumeVal > 0) {
            this.setVolume(this.volumeVal - 1);
          }
        })
      Slider({ value: this.volumeVal, min: 0, max: this.volumeMax, step: 1 })
        .layoutWeight(1)
        .onChange((v: number) => {
          this.setVolume(v);
        })
      Image($r('app.media.plus_icon'))
        .width(18)
        .height(18)
        .onClick(() => {
          if (this.volumeVal < this.volumeMax) {
            this.setVolume(this.volumeVal + 1);
          }
        })
    }
    .width('76%')
    .padding(12)
    .backgroundColor('#F2202020')
    .borderRadius(14)
  }

  build() {
    NavDestination() {
      Stack() {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(this.player.trackName)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.player.artistName.length > 0) {
                Text(this.player.artistName)
                  .fontSize(11)
                  .opacity(0.6)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(15)
              .onClick(() => {
                this.navStack.pop();
              })
          }
          .width('100%')

          if (this.player.errorMsg.length > 0) {
            Text(this.player.errorMsg)
              .fontSize(11)
              .fontColor(Color.Red)
          }

          Stack({ alignContent: Alignment.Center }) {
            Stack() {
              Circle({ width: 90, height: 90 })
                .fill(Color.Transparent)
                .stroke('#11FFFFFF')
                .strokeWidth(3)
              Circle({ width: 90, height: 90 })
                .fill(Color.Transparent)
                .stroke('#FF3EB575')
                .strokeWidth(3)
                .strokeLineCap(LineCapStyle.Round)
                .strokeDashArray(this.ringDash())
            }
            .width(96)
            .height(96)
            .rotate({ angle: -90 })
            Image($r('app.media.prev_icon'))
              .width(22)
              .height(22)
              .offset({ x: -68 })
              .onClick(() => {
                playerModel.prev();
              })
            Image($r('app.media.next_icon'))
              .width(22)
              .height(22)
              .offset({ x: 68 })
              .onClick(() => {
                playerModel.next();
              })
            if (this.coverFail) {
              Column() {
                Image($r('app.media.note_icon'))
                  .width(30)
                  .height(30)
                  .opacity(0.5)
              }
              .width(80)
              .height(80)
              .borderRadius(40)
              .justifyContent(FlexAlign.Center)
              .backgroundColor('#1AFFFFFF')
            } else {
              if (this.coverPixelMap !== null) {
                Image(this.coverPixelMap)
                  .width(80)
                  .height(80)
                  .borderRadius(40)
                  .border({ width: 1, color: '#33FFFFFF' })
                  .shadow({ radius: 18, color: '#4DFFFFFF', offsetY: 0 })
              } else {
                Column() {
                  Image($r('app.media.note_icon'))
                    .width(30)
                    .height(30)
                    .opacity(0.5)
                }
                .width(80)
                .height(80)
                .borderRadius(40)
                .justifyContent(FlexAlign.Center)
                .backgroundColor('#1AFFFFFF')
              }
            }
            Button() {
              SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
                .fontSize(15)
                .fontColor(['#FF000000'])
            }
            .width(34)
            .height(34)
            .borderRadius(17)
            .backgroundColor('#99FFFFFF')
            .onClick(() => {
              playerModel.toggle();
            })
          }
          .layoutWeight(1)
          .offset({ y: -6 })

          Row({ space: 26 }) {
            Image(this.modeIcon())
              .width(20)
              .height(20)
              .onClick(() => {
                playerModel.cycleMode();
              })
            Image($r('app.media.speaker_icon'))
              .width(20)
              .height(20)
              .onClick(() => {
                this.openVolume();
              })
            Image($r('app.media.queue_icon'))
              .width(20)
              .height(20)
              .onClick(() => {
                this.openPlaylist();
              })
          }
          .justifyContent(FlexAlign.Center)
          .padding({ bottom: 4 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 34, right: 34, top: 24, bottom: 30 })
        .id('playerPageRoot')
        .focusable(true)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onAppear(() => {
          this.reqFocus('playerPageRoot');
        })
/** 表冠调音量：事件按累积角度计（每事件约 ±3°），累计满 30° 调一格；
   * 负号是为了让旋转方向符合手表习惯（上调向外/向下，可按需翻转） */
        .onDigitalCrown((event: CrownEvent): void => {
          if (this.crownVol < 0) {
            return;
          }
          if (event.action === CrownAction.BEGIN) {
            this.crownAccum = 0;
            return;
          }
          if (event.action !== CrownAction.UPDATE) {
            return;
          }
          this.crownAccum -= event.degree;
          while (this.crownAccum >= 30) {
            this.crownAccum -= 30;
            this.bumpVolume(1);
          }
          while (this.crownAccum <= -30) {
            this.crownAccum += 30;
            this.bumpVolume(-1);
          }
        })
        /** 左滑（位移 < -80）进入歌词路由页；阈值放大是为了避开系统边缘手势误触 */
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.touchStartX = event.touches[0].x;
          } else if (event.type === TouchType.Up && this.touchStartX >= 0) {
            const dx: number = event.changedTouches[0].x - this.touchStartX;
            this.touchStartX = -1;
            if (dx < -80) {
              this.navStack.pushPath({ name: 'lyrics' });
            }
          }
        })

        if (this.playlistOpen) {
          this.playlistView();
        }
        if (this.volumeOpen) {
          Column() {
            this.volumePanel();
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#99000000')
          .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
          .onClick(() => {
            this.volumeOpen = false;
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#E6000000')
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
    })
/** 返回链：先关播放列表/音量弹层，弹层都关了才允许系统弹出详情页（回到曲库） */
    .onBackPressed(() => {
      if (this.playlistOpen) {
        this.playlistOpen = false;
        return true;
      }
      if (this.volumeOpen) {
        this.volumeOpen = false;
        return true;
      }
      return false;
    })
  }
}

@Builder
export function PlayerPageBuilder() {
  PlayerPage();
}
