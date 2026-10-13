/**
 * 全局统一菜单组件：首页与文件夹页共用。
 * 排序（展开/返回/升降序）、网络状态与重绑、退出登录、更换服务器、关闭应用。
 * 账号操作通过 AppStorage 计数器通知 Index 执行，以规避路由页无法直接回调首页的问题。
 */
import { CtxHolder } from '../common/CtxHolder';
import { AppConfig } from '../common/AppConfig';

export const BITRATE_KBPS: number[] = [320, 192, 128, 96, 64];

export const SORT_KEYS: string[] = ['SortName', 'DateCreated', 'AlbumArtist'];
export const SORT_LABELS: string[] = ['名称', '时间', '歌手'];

@Component
export struct MenuPanel {
  @Prop sortKey: string;
  @Prop sortAsc: boolean;
  @Prop netText: string;
  @StorageProp('maxBitrate') maxBitrate: number = 128000;
  @State sortExpanded: boolean = false;
  @State bitrateExpanded: boolean = false;
  onSort: (key: string) => void = () => {
  };
  onNet: () => void = () => {
  };
  onClose: () => void = () => {
  };

/** 排序主行文案：排序：字段（方向由右侧箭头图标表达，不用文字） */
  private sortText(): string {
    const idx: number = SORT_KEYS.indexOf(this.sortKey);
    const label: string = idx >= 0 ? SORT_LABELS[idx] : '名称';
    return `排序：${label}`;
  }

/** 码率主行文案 */
  private bitrateText(): string {
    const kbps: number = Math.round(this.maxBitrate / 1000);
    return `码率：${kbps}k`;
  }

/** 选择码率：写入 AppStorage 即时生效（作用于下一首起流），并持久化 */
  private selectBitrate(v: number): void {
    AppStorage.setOrCreate('maxBitrate', v);
    const ctx = CtxHolder.ctx;
    if (ctx !== null) {
      AppConfig.saveBitrate(ctx, v);
    }
  }

/** 码率选项行 */
  @Builder
  private bitrateRow(kbps: number) {
    Row() {
      Text(`${kbps}k`)
        .fontSize(12)
        .fontColor(this.maxBitrate === kbps * 1000 ? '#FF3EB575' : '#FFFFFFFF')
        .layoutWeight(1)
    }
    .width('100%')
    .height(34)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.maxBitrate === kbps * 1000 ? '#33FFFFFF' : '#26FFFFFF')
    .borderRadius(10)
    .onClick(() => {
      this.selectBitrate(kbps * 1000);
    })
  }

/** 退出登录：路由页无法直接回调首页，用 AppStorage 计数器通知 Index 执行（观察者模式） */
  private requestLogout(): void {
    const n = AppStorage.get<number>('logoutRequest') ?? 0;
    AppStorage.setOrCreate('logoutRequest', n + 1);
  }

  private requestChangeServer(): void {
    const n = AppStorage.get<number>('changeServerRequest') ?? 0;
    AppStorage.setOrCreate('changeServerRequest', n + 1);
  }

  private exitApp(): void {
    const ctx = CtxHolder.ctx;
    if (ctx !== null) {
      ctx.terminateSelf();
    }
  }

  @Builder
  private menuRow(label: string, icon: Resource, action: () => void) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor('#FFFFFFFF')
        .layoutWeight(1)
      Image(icon)
        .width(15)
        .height(15)
        .opacity(0.8)
    }
    .width('100%')
    .height(34)
    .padding({ left: 12, right: 12 })
    .backgroundColor('#26FFFFFF')
    .borderRadius(10)
    .onClick(() => {
      action();
    })
  }

  @Builder
  private sortRow(key: string, label: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(this.sortKey === key ? '#FF3EB575' : '#FFFFFFFF')
        .layoutWeight(1)
      if (this.sortKey === key) {
        Image(this.sortAsc ? $r('app.media.arrow_up_icon') : $r('app.media.arrow_down_icon'))
          .width(12)
          .height(12)
          .fillColor('#FF3EB575')
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.sortKey === key ? '#33FFFFFF' : '#26FFFFFF')
    .borderRadius(10)
    .onClick(() => {
      this.onSort(key);
    })
  }

  build() {
    Scroll() {
      Column({ space: 8 }) {
        if (!this.sortExpanded && !this.bitrateExpanded) {
          Text('菜单')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
          this.menuRow(this.sortText(), this.sortAsc ? $r('app.media.arrow_up_icon') : $r('app.media.arrow_down_icon'),
            (): void => {
              this.sortExpanded = true;
            })
          this.menuRow(`网络：${this.netText}`, $r('app.media.wifi_icon'), (): void => {
            this.onNet();
          })
          this.menuRow(this.bitrateText(), $r('app.media.speaker_icon'), (): void => {
            this.bitrateExpanded = true;
          })
          this.menuRow('退出登录', $r('app.media.logout_icon'), (): void => {
            this.requestLogout();
          })
          this.menuRow('更换服务器', $r('app.media.server_icon'), (): void => {
            this.requestChangeServer();
          })
          this.menuRow('关闭应用', $r('app.media.logout_icon'), (): void => {
            this.exitApp();
          })
        } else if (this.bitrateExpanded) {
          Text('播放码率')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
          ForEach(BITRATE_KBPS, (kbps: number) => {
            this.bitrateRow(kbps);
          }, (kbps: number) => `${kbps}`)
          this.menuRow('返回', $r('app.media.prev_icon'), (): void => {
            this.bitrateExpanded = false;
          })
        } else {
          Text('排序方式')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
          ForEach(SORT_LABELS, (label: string, idx: number) => {
            this.sortRow(SORT_KEYS[idx], label);
          }, (label: string) => label)
          this.menuRow('返回', $r('app.media.prev_icon'), (): void => {
            this.sortExpanded = false;
          })
        }
        this.menuRow('关闭菜单', $r('app.media.close_icon'), (): void => {
          this.onClose();
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 48, bottom: 30 })
    .backgroundColor('#F2000000')
  }
}
