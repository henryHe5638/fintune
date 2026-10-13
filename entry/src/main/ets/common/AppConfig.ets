/**
 * 本地持久化（preferences）：服务器地址、登录 token、用户信息、
 * 排序方式、播放状态（队列+下标+浏览路径，用于重启恢复续播与层级定位）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'wrist_music_config';
const KEY_SERVER_URL: string = 'server_url';
const KEY_ACCESS_TOKEN: string = 'access_token';
const KEY_USER_ID: string = 'user_id';
const KEY_USER_NAME: string = 'user_name';
const KEY_SORT_KEY: string = 'sort_key';
const KEY_SORT_ASC: string = 'sort_asc';
const KEY_BITRATE: string = 'max_bitrate';
const KEY_PLAY_STATE: string = 'play_state';

export class AppConfig {
/** 读取全部配置项（服务器/令牌/用户） */
  static async load(ctx: common.Context): Promise<Record<string, string>> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    const out: Record<string, string> = {};
    out[KEY_SERVER_URL] = await prefs.get(KEY_SERVER_URL, '') as string;
    out[KEY_ACCESS_TOKEN] = await prefs.get(KEY_ACCESS_TOKEN, '') as string;
    out[KEY_USER_ID] = await prefs.get(KEY_USER_ID, '') as string;
    out[KEY_USER_NAME] = await prefs.get(KEY_USER_NAME, '') as string;
    return out;
  }

/** 保存服务器地址（配置成功时） */
  static async saveServer(ctx: common.Context, serverUrl: string): Promise<void> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    await prefs.put(KEY_SERVER_URL, serverUrl);
    await prefs.flush();
  }

/** 保存登录凭证（token 只存在手表本地 preferences） */
  static async saveAuth(ctx: common.Context, accessToken: string, userId: string, userName: string): Promise<void> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    await prefs.put(KEY_ACCESS_TOKEN, accessToken);
    await prefs.put(KEY_USER_ID, userId);
    await prefs.put(KEY_USER_NAME, userName);
    await prefs.flush();
  }

/** 持久化排序方式（重启保留） */
  static async saveSort(ctx: common.Context, sortKey: string, sortAsc: boolean): Promise<void> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    await prefs.put(KEY_SORT_KEY, sortKey);
    await prefs.put(KEY_SORT_ASC, sortAsc ? '1' : '0');
    await prefs.flush();
  }

  static async loadSort(ctx: common.Context): Promise<Record<string, string>> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    const out: Record<string, string> = {};
    out[KEY_SORT_KEY] = await prefs.get(KEY_SORT_KEY, '') as string;
    out[KEY_SORT_ASC] = await prefs.get(KEY_SORT_ASC, '1') as string;
    return out;
  }

/** 持久化播放码率（服务器转码上限，弱网/蜂窝环境可手动调低省流量省电） */
  static async saveBitrate(ctx: common.Context, maxBitrate: number): Promise<void> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    await prefs.put(KEY_BITRATE, `${maxBitrate}`);
    await prefs.flush();
  }

  static async loadBitrate(ctx: common.Context): Promise<number> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    const raw: string = await prefs.get(KEY_BITRATE, '128000') as string;
    const n: number = Number(raw);
    return n > 0 ? n : 128000;
  }

/** 持久化播放状态：JSON 字符串含 浏览路径 path / 播放队列 queue / 下标 index，用于重启恢复续播与层级定位 */
  static async savePlayState(ctx: common.Context, json: string): Promise<void> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    await prefs.put(KEY_PLAY_STATE, json);
    await prefs.flush();
  }

  static async loadPlayState(ctx: common.Context): Promise<string> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    return await prefs.get(KEY_PLAY_STATE, '') as string;
  }

/** 退出登录：清凭证但保留服务器地址 */
  static async clearAuth(ctx: common.Context): Promise<void> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    await prefs.delete(KEY_ACCESS_TOKEN);
    await prefs.delete(KEY_USER_ID);
    await prefs.delete(KEY_USER_NAME);
    await prefs.flush();
  }

/** 更换服务器：全部配置清空（含播放状态） */
  static async clearAll(ctx: common.Context): Promise<void> {
    const prefs = await preferences.getPreferences(ctx, STORE_NAME);
    await prefs.clear();
    await prefs.flush();
  }
}
