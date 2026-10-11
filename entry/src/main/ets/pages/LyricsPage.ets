/**
 * 歌词路由页（name='lyrics'）。
 * 兼容三种歌词格式：Jellyfin 包壳 JSON（{Lyrics:[{Start,Text}]}）、裸数组、LRC、纯文本。
 * 当前行高亮并自动滚动居中，双击歌词行 seek 跳转；表冠滚动歌词（手动 scrollBy 方案）。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JellyfinClient } from '../common/JellyfinClient';
import { playerModel, PlayerModel } from '../common/PlayerModel';

interface LyricLine {
  timeMs: number;
  text: string;
}

interface RawLyricLine {
  Start?: number;
  Text?: string;
}

interface RawLyricResponse {
  Lyrics?: RawLyricLine[];
}

@Component
struct LyricsPage {
  @State player: PlayerModel = playerModel;
  @StorageProp('serverUrl') serverUrl: string = '';
  @StorageProp('accessToken') accessToken: string = '';
  @State lyricLines: LyricLine[] = [];
  @State lyricPlain: string = '';
  @State lyricsLoading: boolean = false;
  @State curLyricIndex: number = 0;
  @State lyricsForId: string = '';
  private navStack: NavPathStack = new NavPathStack();
  private lyricTimer: number = -1;
  private listScroller: Scroller = new Scroller();
  private crownAccum: number = 0;

  aboutToAppear(): void {
    this.retryFocus('lyricsRoot', [200, 600, 1200]);
  }

  aboutToDisappear(): void {
    this.stopLyricTimer();
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

  private newClient(): JellyfinClient {
    const c = new JellyfinClient(this.serverUrl);
    c.setToken(this.accessToken);
    return c;
  }

/** 按需拉取歌词：只在曲目变化时请求一次，避免反复进出页面重复请求 */
  private async enterLyrics(): Promise<void> {
    if (this.lyricsForId !== this.player.currentId) {
      this.lyricsForId = this.player.currentId;
      this.lyricsLoading = true;
      this.lyricLines = [];
      this.lyricPlain = '';
      const raw: string = await this.newClient().getLyrics(this.player.currentId);
      this.lyricsLoading = false;
      this.parseLyrics(raw);
      this.curLyricIndex = 0;
    }
    this.startLyricTimer();
  }

/** 歌词格式兼容解析，四种形态：
   * 1) 包壳 JSON：{"Metadata":{},"Lyrics":[{"Start":毫秒,"Text":"..."}]}（Jellyfin 10.9+，Start 做了 ticks>1e8 的兜底换算）
   * 2) 裸 JSON 数组 [{Start,Text}]
   * 3) LRC：[mm:ss.xx] 时间标签，一行多标签展开成多条，按时间排序
   * 4) 纯文本：无时间标签，整段静态展示 */
  private parseLyrics(raw: string): void {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      this.lyricPlain = '暂无歌词';
      return;
    }
    if (trimmed.startsWith('{')) {
      try {
        const obj = JSON.parse(trimmed) as RawLyricResponse;
        const arr: RawLyricLine[] = obj.Lyrics ?? [];
        const lines: LyricLine[] = [];
        for (const it of arr) {
          let start: number = it.Start ?? -1;
          if (start > 100000000) {
            start = start / 10000;
          }
          lines.push({ timeMs: Math.round(start), text: it.Text ?? '' });
        }
        this.lyricLines = lines;
        return;
      } catch (error) {
        this.lyricPlain = trimmed;
        return;
      }
    }
    const lines: LyricLine[] = [];
    const segments: string[] = trimmed.split('\n');
    for (const seg of segments) {
      const matches: RegExpMatchArray | null = seg.match(/\[(\d+):(\d+(?:\.\d+)?)\]/g);
      if (matches !== null) {
        const text: string = seg.replace(/\[\d+:\d+(?:\.\d+)?\]/g, '').trim();
        for (const m of matches) {
          const nums: RegExpMatchArray | null = m.match(/(\d+):(\d+(?:\.\d+)?)/);
          if (nums !== null) {
            const t: number = parseInt(nums[1]) * 60000 + parseFloat(nums[2]) * 1000;
            lines.push({ timeMs: Math.round(t), text: text });
          }
        }
      } else if (seg.trim().length > 0) {
        lines.push({ timeMs: -1, text: seg.trim() });
      }
    }
    if (lines.length > 0 && lines[0].timeMs >= 0) {
      lines.sort((a: LyricLine, b: LyricLine): number => a.timeMs - b.timeMs);
      this.lyricLines = lines;
    } else if (lines.length > 0) {
      this.lyricLines = lines;
    } else {
      this.lyricPlain = trimmed;
    }
  }

/** 歌词定时器（800ms）：切歌检测（曲目 id 变了自动重新拉歌词）+ 按播放进度定位当前行并滚动居中 */
  private startLyricTimer(): void {
    this.stopLyricTimer();
    this.lyricTimer = setInterval(() => {
      if (playerModel.currentId !== this.lyricsForId) {
        this.enterLyrics();
        return;
      }
      const pos: number = playerModel.positionMs;
      let idx: number = 0;
      for (let i = 0; i < this.lyricLines.length; i++) {
        if (this.lyricLines[i].timeMs >= 0 && this.lyricLines[i].timeMs <= pos) {
          idx = i;
        }
      }
      if (idx !== this.curLyricIndex) {
        this.curLyricIndex = idx;
        this.listScroller.scrollToIndex(idx, true, ScrollAlign.CENTER);
      }
    }, 800);
  }

  private stopLyricTimer(): void {
    if (this.lyricTimer >= 0) {
      clearInterval(this.lyricTimer);
      this.lyricTimer = -1;
    }
  }

  build() {
    NavDestination() {
      Stack() {
        if (this.lyricsLoading) {
          Text('加载中…')
            .fontSize(12)
            .opacity(0.6)
        } else if (this.lyricPlain.length > 0) {
          Scroll() {
            Text(this.lyricPlain)
              .fontSize(12)
              .opacity(0.8)
              .width('100%')
          }
          .width('100%')
          .height('100%')
          .padding({ left: 34, right: 34, top: 24, bottom: 30 })
        } else {
          List({ scroller: this.listScroller }) {
            ForEach(this.lyricLines, (line: LyricLine, index: number) => {
              ListItem() {
                Text(line.text.length > 0 ? line.text : '···')
                  .fontSize(index === this.curLyricIndex ? 14 : 11)
                  .fontWeight(index === this.curLyricIndex ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(index === this.curLyricIndex ? '#FFFFFFFF' : '#88FFFFFF')
                  .textAlign(TextAlign.Center)
                  .width('100%')
                  .padding({ left: 20, right: 20, top: 8, bottom: 8 })
                  .gesture(TapGesture({ count: 2 }).onAction(() => {
                    if (line.timeMs >= 0) {
                      playerModel.seekTo(line.timeMs);
                      this.curLyricIndex = index;
                    }
                  }))
              }
            }, (line: LyricLine) => `${line.timeMs}-${line.text}`)
          }
          .width('100%')
          .height('100%')
          .padding({ top: 24, bottom: 30 })
          .id('lyricsRoot')
          .focusable(true)
          .onAppear(() => {
            this.reqFocus('lyricsRoot');
            this.enterLyrics();
          })
/** 表冠滚动歌词：累计 20° 滚动 26px（手动 scrollBy 方案）。
   * 注：本 ROM 上 requestFocus 对 ArcList/部分容器恒返回 false，原生表冠滚动不可用，
   * 故改为普通 List + 手动滚动；若你的设备原生可用，可简化此逻辑 */
          .onDigitalCrown((event: CrownEvent): void => {
            if (event.action !== CrownAction.UPDATE) {
              return;
            }
            this.crownAccum += event.degree;
            while (this.crownAccum >= 20) {
              this.crownAccum -= 20;
              this.listScroller.scrollBy(0, 26);
            }
            while (this.crownAccum <= -20) {
              this.crownAccum += 20;
              this.listScroller.scrollBy(0, -26);
            }
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
  }
}

@Builder
export function LyricsPageBuilder() {
  LyricsPage();
}
