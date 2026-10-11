/**
 * 网络绑定工具：解决"手表蓝牙连手机时流量走蓝牙代理（极慢）"的问题。
 * 通过 connection.setAppNet 把应用流量绑定到指定网络：Wi-Fi 优先、蜂窝兜底、蓝牙次之；
 * 无可用网络时回退系统默认网络。并监听 netAvailable/netLost 自动重绑，
 * 断网时暂停播放、恢复后自动续播（回调挂到 PlayerModel）。
 */

import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'FinTune';

export class NetBinder {
  private static bound: string = '未绑定';
  private static watching: boolean = false;
  private static lastCellular: connection.NetHandle | null = null;
  static onLost: () => void = () => {
  };
  static onAvailable: () => void = () => {
  };

  static currentText(): string {
    return NetBinder.bound;
  }

/** 监听全局网络变化：网络可用/丢失时自动重新绑定，保证流量始终走在最优网络上 */
  static watch(): void {
    if (NetBinder.watching) {
      return;
    }
    NetBinder.watching = true;
    try {
      const conn: connection.NetConnection = connection.createNetConnection();
      conn.on('netAvailable', (): void => {
        NetBinder.bindBest();
        NetBinder.onAvailable();
      });
      conn.on('netLost', (): void => {
        NetBinder.onLost();
        NetBinder.bindBest();
      });
    } catch (error) {
      hilog.warn(0x0001, TAG, 'watch failed');
    }
  }

/** 核心绑定逻辑：遍历所有网络按 bearer 类型 + 连通性验证选网。
 * 除 bearer 外还检查 NET_CAPABILITY_VALIDATED：Wi-Fi 显示"已连接但带感叹号"（无出口）时
 * bearer 仍是 Wi-Fi，但实际不通——公网服务器场景必须跳过它，改走已验证的蜂窝。
 * 选网优先级（公网服务器）：已验证 Wi-Fi > 已验证蜂窝 > 未验证 Wi-Fi > 未验证蜂窝 > 蓝牙 > 默认网；
 * 局域网服务器：任何 Wi-Fi > 蜂窝 > 蓝牙 > 默认网（蜂窝本来就到不了局域网，Wi-Fi 即使无出口也可能是内网）。
 * serverUrl 传流地址或服务器地址均可，用于判断服务器是否在局域网。
 * 每次绑定结果写日志（net bearers / bound to），便于真机排查 */
  static async bindBest(serverUrl?: string): Promise<void> {
    try {
      const needInternet: boolean = serverUrl === undefined ? true : !NetBinder.isLanHost(serverUrl);
      const nets: connection.NetHandle[] = await connection.getAllNets();
      let wifiOk: connection.NetHandle | null = null;
      let wifiBad: connection.NetHandle | null = null;
      let cellOk: connection.NetHandle | null = null;
      let cellBad: connection.NetHandle | null = null;
      let bluetooth: connection.NetHandle | null = null;
      for (const n of nets) {
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(n);
        const validated: boolean = caps.networkCap !== undefined &&
          caps.networkCap.indexOf(connection.NetCap.NET_CAPABILITY_VALIDATED) >= 0;
        let desc: string = validated ? 'ok,' : 'no-internet,';
        for (const t of caps.bearerTypes) {
          desc = `${desc}${t},`;
          if (t === connection.NetBearType.BEARER_WIFI) {
            if (validated && wifiOk === null) {
              wifiOk = n;
            }
            if (!validated && wifiBad === null) {
              wifiBad = n;
            }
          }
          if (t === connection.NetBearType.BEARER_CELLULAR) {
            if (validated && cellOk === null) {
              cellOk = n;
            }
            if (!validated && cellBad === null) {
              cellBad = n;
            }
          }
          if (t === connection.NetBearType.BEARER_BLUETOOTH && bluetooth === null) {
            bluetooth = n;
          }
        }
        hilog.info(0x0001, TAG, 'net bearers: %{public}s', desc);
      }
      NetBinder.lastCellular = cellOk !== null ? cellOk : cellBad;
      let target: connection.NetHandle | null = null;
      let label: string = '';
      if (needInternet) {
        target = wifiOk !== null ? wifiOk : (cellOk !== null ? cellOk :
          (wifiBad !== null ? wifiBad : (cellBad !== null ? cellBad : bluetooth)));
        label = wifiOk !== null ? 'Wi-Fi' : (cellOk !== null ? '蜂窝' :
          (wifiBad !== null ? 'Wi-Fi(未验证)' : (cellBad !== null ? '蜂窝(未验证)' : '蓝牙')));
      } else {
        target = wifiOk !== null ? wifiOk : (wifiBad !== null ? wifiBad :
          (cellOk !== null ? cellOk : (cellBad !== null ? cellBad : bluetooth)));
        label = (wifiOk !== null || wifiBad !== null) ? 'Wi-Fi' : (cellOk !== null ? '蜂窝' : '蓝牙');
      }
      if (target === null) {
        try {
          const def: connection.NetHandle = await connection.getDefaultNet();
          if (def !== undefined) {
            await connection.setAppNet(def);
          }
          NetBinder.bound = '默认';
        } catch (error) {
          NetBinder.bound = '无网络';
        }
        return;
      }
      await connection.setAppNet(target);
      NetBinder.bound = label;
      hilog.info(0x0001, TAG, 'bound to %{public}s', NetBinder.bound);
    } catch (error) {
      hilog.warn(0x0001, TAG, 'bindBest failed');
    }
  }

/** 判断服务器地址是否为局域网主机（内网 IPv4 / localhost / *.local / IPv6 回环）。域名一律视为公网 */
  private static isLanHost(url: string): boolean {
    const m: RegExpMatchArray | null = url.match(/^https?:\/\/\[?([^\]/:]+)\]?(?::\d+)?(?:\/|$)/i);
    if (m === null) {
      return false;
    }
    const host: string = m[1].toLowerCase();
    if (host === 'localhost' || host === '::1' || host.endsWith('.local')) {
      return true;
    }
    const parts: string[] = host.split('.');
    if (parts.length !== 4) {
      return false;
    }
    const seg: number[] = [0, 0, 0, 0];
    for (let i: number = 0; i < 4; i++) {
      if (!/^\d+$/.test(parts[i])) {
        return false;
      }
      seg[i] = Number(parts[i]);
    }
    if (seg[0] === 10 || seg[0] === 127) {
      return true;
    }
    if (seg[0] === 172 && seg[1] >= 16 && seg[1] <= 31) {
      return true;
    }
    if (seg[0] === 192 && seg[1] === 168) {
      return true;
    }
    if (seg[0] === 169 && seg[1] === 254) {
      return true;
    }
    return false;
  }

  /** 播放重试的降网兜底：当前绑 Wi-Fi 则切蜂窝（公网服务器可达），否则回系统默认网络。
   * 解决"手表连着无出口的 Wi-Fi（bearer 是 Wi-Fi 但实际不通）导致播放一直失败"的问题。 */
  static async bindFallback(): Promise<void> {
    try {
      if (NetBinder.bound === 'Wi-Fi' && NetBinder.lastCellular !== null) {
        await connection.setAppNet(NetBinder.lastCellular);
        NetBinder.bound = '蜂窝';
        hilog.info(0x0001, TAG, 'fallback bound to cellular');
        return;
      }
      const def: connection.NetHandle = await connection.getDefaultNet();
      if (def !== undefined) {
        await connection.setAppNet(def);
        NetBinder.bound = '默认';
        hilog.info(0x0001, TAG, 'fallback bound to default');
      }
    } catch (error) {
      hilog.warn(0x0001, TAG, 'bindFallback failed');
    }
  }
}
