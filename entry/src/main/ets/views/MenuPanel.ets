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
  @StorageProp('audioCodec') audioCodec: string = 'mp3';
  @State sortExpanded: boolean = false;
  @State settingsExpanded: boolean = false;
  @State codecPick: boolean = false;
  @State bitratePick: boolean = false;
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

/** 选择码率：写入 AppStorage 即时生效（作用于下一首起流），并持久化 */
  private selectBitrate(v: number): void {
    AppStorage.setOrCreate('maxBitrate', v);
    const ctx = CtxHolder.ctx;
    if (ctx !== null) {
      AppConfig.saveBitrate(ctx, v);
    }
  }

/** 码率选项行；选"原始（不转码）"时灰掉——不转码没有码率概念 */
  @Builder
  private bitrateRow(kbps: number) {
    Row() {
      Text(`${kbps}k`)
        .fontSize(12)
        .fontColor(this.audioCodec === 'raw' ? '#66FFFFFF' :
          (this.maxBitrate === kbps * 1000 ? '#FF3EB575' : '#FFFFFFFF'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(34)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.audioCodec === 'raw' ? '#14FFFFFF' :
      (this.maxBitrate === kbps * 1000 ? '#33FFFFFF' : '#26FFFFFF'))
    .borderRadius(10)
    .onClick(() => {
      if (this.audioCodec !== 'raw') {
        this.selectBitrate(kbps * 1000);
      }
    })
  }

/** 选择转码格式：写入 AppStorage 即时生效（作用于下一首起流），并持久化 */
  private selectCodec(c: string): void {
    AppStorage.setOrCreate('audioCodec', c);
    const ctx = CtxHolder.ctx;
    if (ctx !== null) {
      AppConfig.saveCodec(ctx, c);
    }
  }

/** 格式摘要文案 */
  private codecLabel(): string {
    if (this.audioCodec === 'aac') {
      return 'AAC';
    }
    if (this.audioCodec === 'raw') {
      return '原始（不转码）';
    }
    return 'MP3';
  }

/** 码率摘要文案 */
  private bitrateLabel(): string {
    return `${Math.round(this.maxBitrate / 1000)}k`;
  }

/** 设置项摘要行：左侧名称，右侧当前值（选中色），点击进选择页 */
  @Builder
  private valueRow(label: string, value: string, enabled: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(enabled ? '#FFFFFFFF' : '#66FFFFFF')
        .layoutWeight(1)
      Text(value)
        .fontSize(12)
        .fontColor(enabled ? '#FF3EB575' : '#66FFFFFF')
    }
    .width('100%')
    .height(34)
    .padding({ left: 12, right: 12 })
    .backgroundColor('#26FFFFFF')
    .borderRadius(10)
    .onClick(() => {
      if (enabled) {
        action();
      }
    })
  }

/** 格式选项行 */
  @Builder
  private codecRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(this.audioCodec === value ? '#FF3EB575' : '#FFFFFFFF')
        .layoutWeight(1)
    }
    .width('100%')
    .height(34)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.audioCodec === value ? '#33FFFFFF' : '#26FFFFFF')
    .borderRadius(10)
    .onClick(() => {
      this.selectCodec(value);
    })
  }

/** 退出登录：先弹确认，防误触清凭证（手表屏幕小、菜单项密集） */
  private requestLogout(): void {
    AlertDialog.show({
      title: '退出登录',
      message: '将停止播放并清除登录状态，确定吗？',
      primaryButton: {
        value: '退出',
        action: (): void => {
          const n = AppStorage.get<number>('logoutRequest') ?? 0;
          AppStorage.setOrCreate('logoutRequest', n + 1);
        }
      },
      secondaryButton: { value: '取消', action: (): void => {
      } }
    });
  }

  private requestChangeServer(): void {
    AlertDialog.show({
      title: '更换服务器',
      message: '将停止播放并清除当前服务器的登录与播放状态，确定吗？',
      primaryButton: {
        value: '更换',
        action: (): void => {
          const n = AppStorage.get<number>('changeServerRequest') ?? 0;
          AppStorage.setOrCreate('changeServerRequest', n + 1);
        }
      },
      secondaryButton: { value: '取消', action: (): void => {
      } }
    });
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
        if (!this.sortExpanded && !this.settingsExpanded && !this.codecPick && !this.bitratePick) {
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
          this.menuRow('播放设置', $r('app.media.speaker_icon'), (): void => {
            this.settingsExpanded = true;
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
        } else if (this.codecPick) {
          Text('转码格式')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
          this.codecRow('MP3（兼容最好）', 'mp3')
          this.codecRow('AAC（同音质更小）', 'aac')
          this.codecRow('原始（不转码）', 'raw')
          this.menuRow('返回', $r('app.media.prev_icon'), (): void => {
            this.codecPick = false;
          })
        } else if (this.bitratePick) {
          Text('转码码率')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
          ForEach(BITRATE_KBPS, (kbps: number) => {
            this.bitrateRow(kbps);
          }, (kbps: number) => `${kbps}`)
          this.menuRow('返回', $r('app.media.prev_icon'), (): void => {
            this.bitratePick = false;
          })
        } else if (this.settingsExpanded) {
          Text('播放设置')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
          this.valueRow('转码格式', this.codecLabel(), true, (): void => {
            this.codecPick = true;
          })
          this.valueRow('转码码率', this.audioCodec === 'raw' ? '不可用' : this.bitrateLabel(),
            this.audioCodec !== 'raw', (): void => {
              this.bitratePick = true;
            })
          this.menuRow('返回', $r('app.media.prev_icon'), (): void => {
            this.settingsExpanded = false;
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
