/**
 * 文件夹浏览路由页（系统路由表 name='browse'）。
 * 通过 AppStorage 'browseTarget' 传递 BrowseParam（目标文件夹 id/名称/路径 id 链），
 * 进入时若该层级位于"正在播放歌曲的浏览路径"上，自动滚动定位到对应条目（路径层级）
 * 或正在播放的歌曲本身（歌曲所在文件夹）。排序状态走 AppStorage 全局共享。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JellyfinClient, MediaItem } from '../common/JellyfinClient';
import { playerModel, PlayerModel, TrackInfo } from '../common/PlayerModel';
import { AppConfig } from '../common/AppConfig';
import { NetBinder } from '../common/NetBinder';
import { MenuPanel } from '../views/MenuPanel';

export class BrowseParam {
  parentId: string = '';
  name: string = '';
  pathIds: string[] = [];

  constructor(parentId: string, name: string, pathIds: string[]) {
    this.parentId = parentId;
    this.name = name;
    this.pathIds = pathIds;
  }
}

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
export struct BrowsePage {
  @State parentId: string = '';
  @State name: string = '';
  @State pathIds: string[] = [];
  @State entries: MediaItem[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State player: PlayerModel = playerModel;
  @StorageProp('maxBitrate') maxBitrate: number = 128000;
  @State centerIndex: number = 0;
  @State menuOpen: boolean = false;
  @State sortExpanded: boolean = false;
  @State netText: string = '未绑定';
  @StorageProp('serverUrl') serverUrl: string = '';
  @StorageProp('accessToken') accessToken: string = '';
  @StorageProp('userId') userId: string = '';
  @StorageProp('sortKey') sortKey: string = 'SortName';
  @StorageProp('sortAsc') sortAsc: boolean = true;
  private navStack: NavPathStack = new NavPathStack();
  private listScroller: Scroller = new Scroller();
  private savedPath: string[] = [];
  private touchStartX: number = -1;

  aboutToAppear(): void {
  }

  private reqFocus(id: string): void {
    try {
      focusControl.requestFocus(id);
    } catch (error) {
      hilog.warn(0x0001, 'FinTune', 'reqFocus %{public}s threw', id);
    }
  }

/** 切换排序：同键再点=翻转升降序；写入 AppStorage 全局共享 + 持久化 + 重新加载 */
  private cycleSortKey(key: string): void {
    if (this.sortKey === key) {
      this.sortAsc = !this.sortAsc;
    } else {
      this.sortKey = key;
      this.sortAsc = true;
    }
    AppStorage.setOrCreate('sortKey', this.sortKey);
    AppStorage.setOrCreate('sortAsc', this.sortAsc);
    AppConfig.saveSort(getContext(this), this.sortKey, this.sortAsc);
    this.loadCurrent();
  }

  private rebindNet(): void {
    NetBinder.bindBest(this.serverUrl).then((): void => {
      this.netText = NetBinder.currentText();
    });
  }

/** 从 AppStorage 取浏览参数（BrowseParam：目标文件夹 id/名称/路径 id 链）。
   * 路由参数 pathInfo.param 在 API 26 上类型为 unknown 且 ArkTS 禁止 unknown/断言，
   * 因此改用 AppStorage 传递（写入方：首页/上层文件夹页） */
  private applyParam(): void {    const p = AppStorage.get<BrowseParam>('browseTarget');
    if (p instanceof BrowseParam) {
      this.parentId = p.parentId;
      this.name = p.name;
      this.pathIds = p.pathIds;
    }
  }

/** 读取持久化的播放路径（上次播放歌曲所在的文件夹 id 链），用于进入页面时自动定位 */
  private async loadSavedPath(): Promise<void> {
    try {
      const raw: string = await AppConfig.loadPlayState(getContext(this));
      if (raw.length > 0) {
        const st = JSON.parse(raw) as RawPlayState;
        this.savedPath = st.path ?? [];
      }
    } catch (error) {
    }
  }

  private newClient(): JellyfinClient {
    const c = new JellyfinClient(this.serverUrl);
    c.setToken(this.accessToken);
    return c;
  }

  private async loadCurrent(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      this.entries = await this.newClient().getItems(this.userId, this.parentId, this.sortKey, this.sortAsc);
      const t: number = setTimeout(() => {
        clearTimeout(t);
        this.reqFocus('browseList');
      }, 150);
      this.scrollToSaved();
    } catch (error) {
      this.errorMsg = '加载失败，请检查网络';
    }
    this.loading = false;
  }

  private buildTrackUrl(id: string): string {
    const container: string = encodeURIComponent('mp3,aac|mp3,aac');
    return `${this.serverUrl}/Audio/${id}/universal?container=${container}` +
      `&audioCodec=mp3&maxStreamingBitrate=${this.maxBitrate}`;
  }

  private savePlayState(tracks: TrackInfo[], index: number): void {
    // path 记录的是"歌曲所在的文件夹 id 链"（含当前文件夹，即本页的 pathIds），
    // 浏览页按前缀匹配：中间层定位下一级文件夹，最后一层定位歌曲本身
    const st = JSON.stringify({ path: this.pathIds, queue: tracks, index: index });
    AppConfig.savePlayState(getContext(this), st);
  }

/** 层级定位：当前页面 id 链是播放路径的前缀时 ——
   * 中间层级：滚动到通往歌曲的下一级文件夹；歌曲所在文件夹：滚动到正在播放的那首歌本身 */
  private scrollToSaved(): void {
    if (this.savedPath.length === 0) {
      return;
    }
    for (let i = 0; i < this.pathIds.length; i++) {
      if (i >= this.savedPath.length || this.pathIds[i] !== this.savedPath[i]) {
        return;
      }
    }
    const level: number = this.pathIds.length;
    let targetId: string = '';
    if (level < this.savedPath.length) {
      targetId = this.savedPath[level];
    } else if (level === this.savedPath.length) {
      targetId = playerModel.currentId;
    }
    if (targetId.length === 0) {
      return;
    }
    for (let j = 0; j < this.entries.length; j++) {
      if (this.entries[j].id === targetId) {
        const t: number = setTimeout(() => {
          clearTimeout(t);
          this.listScroller.scrollToIndex(j, true, ScrollAlign.CENTER);
        }, 300);
        return;
      }
    }
  }

/** 条目点击：歌曲=构建当前目录歌曲队列（持久化播放状态后播放）；文件夹=push 更深一层 browse 路由页 */
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
    for (const id of this.pathIds) {
      ids.push(id);
    }
    ids.push(item.id);
    AppStorage.setOrCreate('browseTarget', new BrowseParam(item.id, item.name, ids));
    this.navStack.pushPath({ name: 'browse' });
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
        this.navStack.pushPath({ name: 'player' });
      }
    })
  }

  build() {
    NavDestination() {
      Stack() {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(this.name)
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

        List({ space: 2, scroller: this.listScroller }) {
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
        .id('browseList')
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
              }
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .onReady((ctx: NavDestinationContext) => {
      this.navStack = ctx.pathStack;
      this.applyParam();
      this.loadSavedPath();
      this.loadCurrent();
    })
    .onBackPressed(() => {
      if (this.menuOpen) {
        this.menuOpen = false;
        return true;
      }
      return false;
    })
  }
}

@Builder
export function BrowsePageBuilder() {
  BrowsePage();
}
