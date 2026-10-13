/**
 * 应用入口：Navigation 根容器 + 页面状态机（loading -> 服务器配置 -> 登录 -> 曲库）。
 * 登录态恢复、AppStorage 全局凭据下发、菜单退出/换服务器请求（StorageProp 观察）、系统返回拦截。
 */
import { AppConfig } from '../common/AppConfig';
import { AuthResult } from '../common/JellyfinClient';
import { ServerConfigView } from '../views/ServerConfigView';
import { LoginView } from '../views/LoginView';
import { LibraryBrowserView } from '../views/LibraryBrowserView';
import { playerModel } from '../common/PlayerModel';

@Entry
@Component
struct Index {
  @State stage: string = 'loading';
  @State pageStack: NavPathStack = new NavPathStack();
  @StorageProp('logoutRequest') @Watch('onLogoutReq') logoutReq: number = 0;
  @StorageProp('changeServerRequest') @Watch('onChangeServerReq') changeServerReq: number = 0;
  @State serverUrl: string = '';
  @State accessToken: string = '';
  @State userId: string = '';
  @State userName: string = '';

  aboutToAppear(): void {
    this.restore();
  }

/** 冷启动恢复：读本地配置决定进入哪个阶段（服务器配置/登录/曲库），
   * 同时把凭据写入 AppStorage 供各路由页直接读取 */
  private async restore(): Promise<void> {
    try {
      const cfg = await AppConfig.load(getContext(this));
      this.serverUrl = cfg['server_url'] ?? '';
      this.accessToken = cfg['access_token'] ?? '';
      this.userId = cfg['user_id'] ?? '';
      this.userName = cfg['user_name'] ?? '';
    } catch (error) {
      this.serverUrl = '';
      this.accessToken = '';
    }
    AppStorage.setOrCreate('serverUrl', this.serverUrl);
    AppStorage.setOrCreate('accessToken', this.accessToken);
    AppStorage.setOrCreate('userId', this.userId);
    if (this.serverUrl.length === 0) {
      this.stage = 'server';
    } else if (this.accessToken.length === 0) {
      this.stage = 'login';
    } else {
      this.stage = 'library';
    }
  }

/** 服务器配置成功：持久化并进入登录阶段 */
  private onServerDone(url: string): void {
    this.serverUrl = url;
    const ctx = getContext(this);
    AppConfig.saveServer(ctx, url);
    AppStorage.setOrCreate('serverUrl', url);
    this.stage = 'login';
  }

/** 登录成功：持久化 token 并进入曲库阶段 */
  private onLoginDone(auth: AuthResult): void {
    this.accessToken = auth.accessToken;
    this.userId = auth.userId;
    this.userName = auth.userName;
    const ctx = getContext(this);
    AppConfig.saveAuth(ctx, auth.accessToken, auth.userId, auth.userName);
    AppStorage.setOrCreate('accessToken', auth.accessToken);
    AppStorage.setOrCreate('userId', auth.userId);
    this.stage = 'library';
  }

/** 退出登录：停播并清空队列（token 即将失效，残留队列只会 401）、清凭证、清空路由栈、回登录阶段 */
  private onLogout(): void {
    playerModel.stop();
    AppConfig.clearAuth(getContext(this));
    this.accessToken = '';
    this.userId = '';
    this.userName = '';
    this.pageStack.clear();
    this.stage = 'login';
  }

/** 更换服务器：先停播清队列，再全量清空（含播放状态）、清 AppStorage 凭据、清空路由栈、回配置阶段 */
  private onChangeServer(): void {
    playerModel.stop();
    AppConfig.clearAll(getContext(this));
    this.serverUrl = '';
    this.accessToken = '';
    this.userId = '';
    this.userName = '';
    AppStorage.setOrCreate('serverUrl', '');
    AppStorage.setOrCreate('accessToken', '');
    AppStorage.setOrCreate('userId', '');
    this.pageStack.clear();
    this.stage = 'server';
  }

/** 菜单退出请求（AppStorage 计数器观察）：路由页里的统一菜单通过它通知首页执行 */
  private onLogoutReq(): void {
    if (this.logoutReq > 0) {
      this.onLogout();
    }
  }

/** 菜单换服务器请求，同上 */
  private onChangeServerReq(): void {
    if (this.changeServerReq > 0) {
      this.onChangeServer();
    }
  }

/** 系统返回拦截（右滑/返回键）：有覆盖层（菜单等）先关覆盖层并吞掉返回；否则放行退出 */
  onBackPress(): boolean {
    const open = AppStorage.get<boolean>('overlayOpen');
    if (open === true) {
      AppStorage.setOrCreate('overlayOpen', false);
      return true;
    }
    return false;
  }

  build() {
    Navigation(this.pageStack) {
      Column() {
        if (this.stage === 'loading') {
          Text('FinTune')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
        } else if (this.stage === 'server') {
          ServerConfigView({
            onDone: (url: string): void => {
              this.onServerDone(url);
            }
          })
            .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
        } else if (this.stage === 'login') {
          LoginView({
            serverUrl: this.serverUrl,
            onDone: (auth: AuthResult): void => {
              this.onLoginDone(auth);
            }
          })
            .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
        } else {
          LibraryBrowserView({
            serverUrl: this.serverUrl,
            accessToken: this.accessToken,
            userId: this.userId,
            userName: this.userName,
            stack: this.pageStack
          })
            .transition(TransitionEffect.OPACITY.animation({ duration: 250 }))
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .animation({ duration: 250, curve: Curve.EaseInOut })
    }
    .hideTitleBar(true)
    .hideToolBar(true)
  }
}
