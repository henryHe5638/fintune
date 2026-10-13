/**
 * 首页曲库（Navigation 主页内容）：音乐库列表、点入文件夹（push browse 路由）、
 * 底部播放条（点入详情/滑切歌）、统一菜单（MenuPanel 共享组件）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JellyfinClient, MediaItem } from '../common/JellyfinClient';
import { playerModel, PlayerModel, TrackInfo } from '../common/PlayerModel';
import { NetBinder } from '../common/NetBinder';
import { AppConfig } from '../common/AppConfig';
import { CtxHolder } from '../common/CtxHolder';
import { SessionService } from '../common/SessionService';
import { BrowseParam } from '../pages/BrowsePage';
import { MenuPanel } from './MenuPanel';

interface RawTrackState {
  id?: string;
  name?: string;
  artist?: string;
  url?: string;
  durationMs?: number;
}

interface RawPlayState {
  path?: string[];
  queue?: RawTrackState[];
  index?: number;
}

@Component
export struct LibraryBrowserView {
  serverUrl: string = '';
  accessToken: string = '';
  userId: string = '';
  userName: string = '';
  stack: NavPathStack = new NavPathStack();
  @State entries: MediaItem[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State player: PlayerModel = playerModel;
  @State sortKey: string = 'SortName';
  @State sortAsc: boolean = true;
  @State menuOpen: boolean = false;
  @State sortExpanded: boolean = false;
  @State netText: string = '未绑定';
  @State centerIndex: number = 0;
  @StorageProp('maxBitrate') maxBitrate: number = 128000;
  @StorageProp('overlayOpen') @Watch('onOverlayFlag') overlayFlag: boolean = false;
  private mainListScroller: Scroller = new Scroller();
  private savedPath: string[] = [];

  aboutToAppear(): void {
    this.loadCurrent();
    this.rebindNet();
    NetBinder.watch();
    this.restoreSort();
    this.restorePlayState();
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
      });
    }
    const t: number = setTimeout(() => {
      clearTimeout(t);
      this.reqFocus('mainList');
    }, 400);
  }

/** 安全聚焦：requestFocus 在祖先不可获焦时会抛 150002 异常（曾导致闪退），必须 try/catch */
  private reqFocus(id: string): void {
    try {
      const ok: boolean = focusControl.requestFocus(id);
      hilog.info(0x0001, 'FinTune', 'reqFocus %{public}s -> %{public}s', id, `${ok}`);
    } catch (error) {
      hilog.warn(0x0001, 'FinTune', 'reqFocus %{public}s threw', id);
    }
  }

/** 系统返回拦截的配合观察：overlayOpen 变 false（返回键触发）时关闭全部覆盖层 */
  private onOverlayFlag(): void {
    if (!this.overlayFlag) {
      this.menuOpen = false;
      this.sortExpanded = false;
    }
  }

  private recomputeOverlay(): void {
    AppStorage.setOrCreate('overlayOpen', this.menuOpen);
  }

  private newClient(): JellyfinClient {
    const c = new JellyfinClient(this.serverUrl);
    c.setToken(this.accessToken);
    return c;
  }

/** 加载音乐库列表（首页只展示 collectionType 为 music 的库）；完成后延迟聚焦列表（表冠滚动需要焦点） */
  private async loadCurrent(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      const views = await this.newClient().getUserViews(this.userId);
      const out: MediaItem[] = [];
      for (const v of views) {
        if (v.collectionType === 'music') {
          out.push({ id: v.id, name: v.name, type: 'MusicLibrary', artistNames: '', runTimeTicks: 0 });
        }
      }
      this.entries = out;
      const t: number = setTimeout(() => {
        clearTimeout(t);
        this.reqFocus('mainList');
      }, 150);
      this.scrollToSaved();
    } catch (error) {
      this.errorMsg = '加载失败，请检查网络';
    }
    this.loading = false;
  }

  private buildTrackUrl(id: string): string {
    // Jellyfin 通用转码端点：container 声明可直出的格式（直出优先），audioCodec=mp3 让服务器
    // 统一转码为 MP3 渐进流（audio/mpeg）。不要加 transcodingProtocol=hls —— 返回的 HLS
    // master playlist 在鸿蒙媒体引擎上报 5400106 Unsupported Format（实测坑）。
    // token 只能走 api_key query（AVPlayer 播放网络 URL 无法带自定义请求头）。
    const container: string = encodeURIComponent('mp3,aac|mp3,aac');
    return `${this.serverUrl}/Audio/${id}/universal?userId=${this.userId}&api_key=${this.accessToken}` +
      `&container=${container}&audioCodec=mp3&maxStreamingBitrate=${this.maxBitrate}`;
  }

/** 首页条目点击：歌曲=构建队列播放；文件夹=push browse 路由页（进入子文件夹） */
  private openEntry(item: MediaItem): void {
    if (item.type === 'Audio') {
      const tracks: TrackInfo[] = [];
      let tapIndex: number = 0;
      for (const e of this.entries) {
        if (e.type === 'Audio') {
          if (e.id === item.id) {
            tapIndex = tracks.length;
          }
          tracks.push({
            id: e.id,
            name: e.name,
            artist: e.artistNames,
            url: this.buildTrackUrl(e.id),
            durationMs: Math.round(e.runTimeTicks / 10000)
          });
        }
      }
      this.savePlayState(tracks, tapIndex);
      playerModel.requestPlay(tracks, tapIndex);
      return;
    }
    const ids: string[] = [];
    for (const id of [item.id]) {
      ids.push(id);
    }
    AppStorage.setOrCreate('browseTarget', new BrowseParam(item.id, item.name, ids));
    this.stack.pushPath({ name: 'browse' });
  }

/** 冷启动恢复播放状态：解析持久化 JSON，恢复播放队列与浏览路径（savedPath 用于首页层级定位） */
  private async restorePlayState(): Promise<void> {
    try {
      const raw: string = await AppConfig.loadPlayState(getContext(this));
      if (raw.length === 0) {
        return;
      }
      const st = JSON.parse(raw) as RawPlayState;
      this.savedPath = st.path ?? [];
      const tracks: TrackInfo[] = [];
      for (const q of st.queue ?? []) {
        tracks.push({
          id: q.id ?? '',
          name: q.name ?? '',
          artist: q.artist ?? '',
          url: q.url ?? '',
          durationMs: q.durationMs ?? 0
        });
      }
      playerModel.restore(tracks, st.index ?? 0);
    } catch (error) {
      hilog.warn(0x0001, 'FinTune', 'restore play state failed');
    }
  }

  private savePlayState(tracks: TrackInfo[], index: number): void {
    const st = JSON.stringify({ path: [], queue: tracks, index: index });
    AppConfig.savePlayState(getContext(this), st);
  }

/** 首页层级定位：播放路径第一层是某个音乐库/文件夹时，滚动定位到它 */
  private scrollToSaved(): void {
    if (this.savedPath.length === 0) {
      return;
    }
    const level: number = 0;
    if (level >= this.savedPath.length) {
      return;
    }
    const targetId: string = this.savedPath[level];
    for (let j = 0; j < this.entries.length; j++) {
      if (this.entries[j].id === targetId) {
        const t: number = setTimeout(() => {
          clearTimeout(t);
          this.mainListScroller.scrollToIndex(j, true, ScrollAlign.CENTER);
        }, 300);
        return;
      }
    }
  }

  private async restoreSort(): Promise<void> {
    try {
      const s = await AppConfig.loadSort(getContext(this));
      const k: string = s['sort_key'] ?? '';
      if (k.length > 0) {
        this.sortKey = k;
        this.sortAsc = (s['sort_asc'] ?? '1') === '1';
        AppStorage.setOrCreate('sortKey', this.sortKey);
        AppStorage.setOrCreate('sortAsc', this.sortAsc);
      }
    } catch (error) {
    }
  }

  private cycleSortKey(key: string): void {
    if (this.sortKey === key) {
      this.sortAsc = !this.sortAsc;
    } else {
      this.sortKey = key;
      this.sortAsc = true;
    }
    AppConfig.saveSort(getContext(this), this.sortKey, this.sortAsc);
    AppStorage.setOrCreate('sortKey', this.sortKey);
    AppStorage.setOrCreate('sortAsc', this.sortAsc);
    this.loadCurrent();
  }

  private rebindNet(): void {
    NetBinder.bindBest(this.serverUrl).then((): void => {
      this.netText = NetBinder.currentText();
    });
  }

  @Builder
  private entryRow(item: MediaItem) {
    Row({ space: 6 }) {
      if (this.player.currentId === item.id && item.id.length > 0) {
        Image($r('app.media.note_icon'))
          .width(14)
          .height(14)
          .fillColor('#FF3EB575')
      } else {
        Image(item.type === 'Audio' ? $r('app.media.note_icon') : $r('app.media.folder_icon'))
          .width(14)
          .height(14)
          .opacity(0.6)
      }
      Column({ space: 2 }) {
        Text(item.name)
          .fontSize(14)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.artistNames.length > 0) {
          Text(item.artistNames)
            .fontSize(11)
            .opacity(0.5)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      this.openEntry(item);
    })
  }

  @Builder
  private nowPlayingBar() {
    Row({ space: 6 }) {
      Column({ space: 2 }) {
        Text(this.player.trackName)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.player.artistName.length > 0) {
          Text(this.player.artistName)
            .fontSize(10)
            .opacity(0.6)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
        .fontSize(15)
        .fontColor(['#FFFFFFFF'])
        .onClick(() => {
          playerModel.toggle();
        })
      Image($r('app.media.stop_icon'))
        .width(15)
        .height(15)
        .onClick(() => {
          playerModel.stop();
        })
    }
    .width('100%')
    .padding(8)
    .backgroundColor('#22FFFFFF')
    .borderRadius(10)
    .onClick(() => {
      if (this.player.currentId.length > 0) {
        this.stack.pushPath({ name: 'player' });
      }
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.touchStartX = event.touches[0].x;
      } else if (event.type === TouchType.Up && this.touchStartX >= 0) {
        const dx: number = event.changedTouches[0].x - this.touchStartX;
        this.touchStartX = -1;
        if (dx < -40) {
          playerModel.next();
        } else if (dx > 40) {
          playerModel.prev();
        }
      }
    })
  }

  private touchStartX: number = -1;

  build() {
    Stack() {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(`${this.userName} 的曲库`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button() {
            Image($r('app.media.more_icon'))
              .width(16)
              .height(16)
          }
          .width(30)
          .height(26)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.menuOpen = true;
            this.recomputeOverlay();
            const t: number = setTimeout(() => {
              clearTimeout(t);
              this.reqFocus('menuScroll');
            }, 300);
          })
        }
        .width('100%')

        if (this.loading) {
          Text('加载中…')
            .fontSize(12)
            .opacity(0.6)
        }
        if (this.errorMsg.length > 0) {
          Text(this.errorMsg)
            .fontSize(12)
            .fontColor(Color.Red)
        }

        List({ space: 2, scroller: this.mainListScroller }) {
          ForEach(this.entries, (item: MediaItem, idx: number) => {
            ListItem() {
              Column() {
                this.entryRow(item);
              }
              .width('100%')
              .backgroundColor(idx === this.centerIndex ? '#14FFFFFF' : Color.Transparent)
              .borderRadius(8)
            }
          }, (item: MediaItem) => item.id)
        }
        .id('mainList')
        .focusable(true)
        .focusOnTouch(true)
        .onScrollIndex((start: number, end: number, center: number): void => {
          this.centerIndex = center;
        })
        .layoutWeight(1)
        .width('100%')

        if (this.player.errorMsg.length > 0) {
          Text(this.player.errorMsg)
            .fontSize(11)
            .fontColor(Color.Red)
        }

        if (this.player.trackName.length > 0) {
          this.nowPlayingBar();
        }
      }
      .padding({ left: 34, right: 34, top: 24, bottom: 30 })
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.menuOpen) {
        Column() {
          MenuPanel({
            sortKey: this.sortKey,
            sortAsc: this.sortAsc,
            netText: this.netText,
            onSort: (key: string): void => {
              this.cycleSortKey(key);
            },
            onNet: (): void => {
              this.rebindNet();
            },
            onClose: (): void => {
              this.menuOpen = false;
              this.recomputeOverlay();
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.touchStartX = event.touches[0].x;
          } else if (event.type === TouchType.Up && this.touchStartX >= 0) {
            const dx: number = event.changedTouches[0].x - this.touchStartX;
            this.touchStartX = -1;
            if (dx > 40) {
              this.menuOpen = false;
              this.recomputeOverlay();
            }
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .animation({ duration: 200, curve: Curve.EaseInOut })
  }
}
