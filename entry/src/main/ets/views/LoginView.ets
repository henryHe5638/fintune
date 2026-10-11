/** 账密登录页：Jellyfin AuthenticateByName，返回的 access token 自动持久化。 */
import { JellyfinClient, AuthResult } from '../common/JellyfinClient';

@Component
export struct LoginView {
  serverUrl: string = '';
  @State username: string = '';
  @State password: string = '';
  @State loggingIn: boolean = false;
  @State errorMsg: string = '';
  onDone: (auth: AuthResult) => void = () => {
  };

/** 账密登录：Jellyfin AuthenticateByName 换 access token，成功回调上层保存并进入曲库 */
  private async doLogin(): Promise<void> {
    if (this.username.trim().length === 0) {
      this.errorMsg = '请输入用户名';
      return;
    }
    this.loggingIn = true;
    this.errorMsg = '';
    const client = new JellyfinClient(this.serverUrl);
    try {
      const auth: AuthResult = await client.authenticateByName(this.username.trim(), this.password);
      this.loggingIn = false;
      this.onDone(auth);
    } catch (error) {
      this.loggingIn = false;
      this.errorMsg = '登录失败，请检查账密';
    }
  }

  build() {
    Column({ space: 10 }) {
      Text('登录 Jellyfin')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
      Text(this.serverUrl)
        .fontSize(11)
        .opacity(0.5)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      TextInput({ placeholder: '用户名', text: this.username })
        .onChange((value: string) => {
          this.username = value;
        })
        .fontSize(14)
      TextInput({ placeholder: '密码', text: this.password })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.password = value;
        })
        .fontSize(14)
      if (this.loggingIn) {
        Text('登录中…')
          .fontSize(12)
          .opacity(0.6)
      }
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(12)
          .fontColor(Color.Red)
      }
      Button('登录')
        .onClick(() => {
          this.doLogin();
        })
        .enabled(!this.loggingIn)
        .width('80%')
    }
    .justifyContent(FlexAlign.Center)
    .padding(12)
    .width('100%')
    .height('100%')
  }
}
