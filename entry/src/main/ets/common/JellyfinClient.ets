/**
 * Jellyfin REST API 客户端。
 * 负责：服务器探测(System/Info/Public)、账密登录(AuthenticateByName)、
 * 曲库浏览(UserViews/Items)、歌词拉取(/Audio/{id}/Lyrics)。
 * 认证方式：登录后使用 access token（X-Emby-Token 头），token 由账密登录自动获得，
 * 全程无需用户接触 API Key。网络请求失败时自动重新绑定网络并重试一次（弱网恢复）。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NetBinder } from './NetBinder';

const TAG: string = 'FinTune';

export interface SystemInfo {
  serverName: string;
  version: string;
}

export interface AuthResult {
  accessToken: string;
  userId: string;
  userName: string;
}

export interface LibraryView {
  id: string;
  name: string;
  collectionType: string;
}

export interface MediaItem {
  id: string;
  name: string;
  type: string;
  artistNames: string;
  runTimeTicks: number;
}

interface RawSystemInfo {
  ServerName?: string;
  Version?: string;
}

interface RawAuthUser {
  Id?: string;
  Name?: string;
}

interface RawAuth {
  AccessToken?: string;
  User?: RawAuthUser;
}

interface RawViewItem {
  Id?: string;
  Name?: string;
  CollectionType?: string;
}

interface RawViews {
  Items?: RawViewItem[];
}

interface RawMediaItem {
  Id?: string;
  Name?: string;
  Type?: string;
  AlbumArtist?: string;
  Artists?: string[];
  RunTimeTicks?: number;
}

interface RawItems {
  Items?: RawMediaItem[];
}

export class JellyfinClient {
  private serverUrl: string;
  private accessToken: string = '';

  constructor(serverUrl: string) {
    this.serverUrl = serverUrl.replace(/\/+$/, '');
  }

  setToken(token: string): void {
    this.accessToken = token;
  }

  getServerUrl(): string {
    return this.serverUrl;
  }

/** 统一请求入口：失败时自动重新绑定网络（NetBinder.bindBest）并延迟 800ms 重试一次，
   * 解决 Wi-Fi 切换/蓝牙代理导致的 DNS 解析失败与超时（弱网自愈） */
  private async request(path: string, method: http.RequestMethod, extraData?: string): Promise<string> {
    try {
      return await this.doRequest(path, method, extraData);
    } catch (error) {
      hilog.warn(0x0001, TAG, 'request failed, rebind and retry once');
      NetBinder.bindBest();
      await new Promise<void>((resolve: () => void): void => {
        const tt: number = setTimeout(() => {
          clearTimeout(tt);
          resolve();
        }, 800);
      });
      return await this.doRequest(path, method, extraData);
    }
  }

/** 单次请求实现：带 X-Emby-Authorization 标识客户端；有 token 时带 X-Emby-Token 头；
   * 2xx 返回 body 文本，其余抛错交给上层重试逻辑 */
  private async doRequest(path: string, method: http.RequestMethod, extraData?: string): Promise<string> {
    const httpRequest = http.createHttp();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'X-Emby-Authorization':
        'MediaBrowser Client="FinTune", Device="HuaweiWatch6", DeviceId="wristmusic-watch6-001", Version="1.0.0"'
    };
    if (this.accessToken.length > 0) {
      headers['X-Emby-Token'] = this.accessToken;
    }
    try {
      const resp = await httpRequest.request(this.serverUrl + path, {
        method: method,
        header: headers,
        extraData: extraData,
        connectTimeout: 5000,
        readTimeout: 12000
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        return resp.result as string;
      }
      throw new Error(`HTTP ${resp.responseCode}`);
    } catch (error) {
      hilog.error(0x0001, TAG, 'request failed: %{public}s', JSON.stringify(error));
      throw new Error('网络请求失败，请检查网络或服务器地址');
    } finally {
      httpRequest.destroy();
    }
  }

/** 探测服务器（System/Info/Public 无需鉴权）：配置页测试连接用 */
  async getSystemInfo(): Promise<SystemInfo> {
    const raw = JSON.parse(await this.request('/System/Info/Public', http.RequestMethod.GET)) as RawSystemInfo;
    return { serverName: raw.ServerName ?? '', version: raw.Version ?? '' };
  }

/** 账密登录（/Users/AuthenticateByName）：Jellyfin 原生接口免 API Key，
   * 返回的 access token 即后续所有请求的凭证 */
  async authenticateByName(username: string, password: string): Promise<AuthResult> {
    const body = JSON.stringify({ Username: username, Pw: password });
    const raw =
      JSON.parse(await this.request('/Users/AuthenticateByName', http.RequestMethod.POST, body)) as RawAuth;
    const token: string = raw.AccessToken ?? '';
    if (token.length === 0) {
      throw new Error('登录失败：服务器未返回 access token');
    }
    return {
      accessToken: token,
      userId: raw.User?.Id ?? '',
      userName: raw.User?.Name ?? ''
    };
  }

/** 获取用户媒体库列表（/UserViews），首页只展示音乐库（collectionType === 'music'） */
  async getUserViews(userId: string): Promise<LibraryView[]> {
    const raw = JSON.parse(await this.request(`/UserViews?userId=${userId}`, http.RequestMethod.GET)) as RawViews;
    const out: LibraryView[] = [];
    for (const it of raw.Items ?? []) {
      out.push({ id: it.Id ?? '', name: it.Name ?? '', collectionType: it.CollectionType ?? '' });
    }
    return out;
  }

/** 浏览文件夹内容（/Items）：recursive=false 只看当前层；sortBy/sortOrder 由服务端排序 */
  async getItems(userId: string, parentId: string, sortBy: string, sortAsc: boolean): Promise<MediaItem[]> {
    const order: string = sortAsc ? 'Ascending' : 'Descending';
    const path =
      `/Items?userId=${userId}&parentId=${parentId}&recursive=false` +
      `&sortBy=${sortBy}&sortOrder=${order}`;
    const raw = JSON.parse(await this.request(path, http.RequestMethod.GET)) as RawItems;
    const out: MediaItem[] = [];
    for (const it of raw.Items ?? []) {
      const artists: string = it.AlbumArtist ?? (it.Artists ? it.Artists.join(', ') : '');
      out.push({
        id: it.Id ?? '',
        name: it.Name ?? '',
        type: it.Type ?? '',
        artistNames: artists,
        runTimeTicks: it.RunTimeTicks ?? 0
      });
    }
    return out;
  }

/** 拉取歌词（/Audio/{id}/Lyrics）：新版 Jellyfin 返回包壳 JSON，旧版/无歌词可能 404 或纯文本，
   * 原样返回字符串，格式兼容解析在歌词页处理；失败返回空串由上层显示暂无歌词 */
  async getLyrics(itemId: string): Promise<string> {
    try {
      return await this.request(`/Audio/${itemId}/Lyrics`, http.RequestMethod.GET);
    } catch (error) {
      return '';
    }
  }
}
