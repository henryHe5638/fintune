/** 服务器配置页：地址输入 + 连通性测试（System/Info/Public）后保存。 */
import { JellyfinClient } from '../common/JellyfinClient';

@Component
export struct ServerConfigView {
  @State serverUrl: string = '';
  @State testing: boolean = false;
  @State errorMsg: string = '';
  onDone: (url: string) => void = () => {
  };

/** 测试并保存：地址非空校验 -> 请求 System/Info/Public 验证连通性 -> 成功回调上层进入登录页 */
  private async testAndSave(): Promise<void> {
    const trimmed: string = this.serverUrl.trim();
    if (trimmed.length === 0) {
      this.errorMsg = '请输入服务器地址';
      return;
    }
    this.testing = true;
    this.errorMsg = '';
    const client = new JellyfinClient(trimmed);
    try {
      await client.getSystemInfo();
      this.testing = false;
      this.onDone(client.getServerUrl());
    } catch (error) {
      this.testing = false;
      this.errorMsg = '连接失败，请检查地址和网络';
    }
  }

  build() {
    Column({ space: 10 }) {
      Text('连接 Jellyfin 服务器')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
      TextInput({ placeholder: 'http://ip:8096', text: this.serverUrl })
        .onChange((value: string) => {
          this.serverUrl = value;
        })
        .fontSize(14)
      if (this.testing) {
        Text('连接中…')
          .fontSize(12)
          .opacity(0.6)
      }
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(12)
          .fontColor(Color.Red)
      }
      Button('测试并保存')
        .onClick(() => {
          this.testAndSave();
        })
        .enabled(!this.testing)
        .width('80%')
    }
    .justifyContent(FlexAlign.Center)
    .padding(12)
    .width('100%')
    .height('100%')
  }
}
