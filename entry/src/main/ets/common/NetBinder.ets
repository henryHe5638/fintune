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

/** 核心绑定逻辑：遍历所有网络按 bearer 类型选网 —— Wi-Fi 优先 > 蜂窝兜底 > 蓝牙代理最次。
   * 注意：绑定蜂窝时无法访问局域网 NAS（192.168.x.x），NAS 场景实际只在 Wi-Fi 下可用；
   * 无任何匹配网络时回绑系统默认网络，避免残留失效绑定导致 DNS 解析失败（日志实测坑）。
   * 每次绑定结果写日志（net bearers / bound to），便于真机排查 */
  static async bindBest(): Promise<void> {
    try {
      const nets: connection.NetHandle[] = await connection.getAllNets();
      let wifi: connection.NetHandle | null = null;
      let cellular: connection.NetHandle | null = null;
      let bluetooth: connection.NetHandle | null = null;
      for (const n of nets) {
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(n);
        let desc: string = '';
        for (const t of caps.bearerTypes) {
          desc = `${desc}${t},`;
          if (t === connection.NetBearType.BEARER_WIFI && wifi === null) {
            wifi = n;
          }
          if (t === connection.NetBearType.BEARER_CELLULAR && cellular === null) {
            cellular = n;
          }
          if (t === connection.NetBearType.BEARER_BLUETOOTH && bluetooth === null) {
            bluetooth = n;
          }
        }
        hilog.info(0x0001, TAG, 'net bearers: %{public}s', desc);
      }
      const target: connection.NetHandle | null = wifi !== null ? wifi : (cellular !== null ? cellular : bluetooth);
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
      NetBinder.bound = wifi !== null ? 'Wi-Fi' : (cellular !== null ? '蜂窝' : '蓝牙');
      hilog.info(0x0001, TAG, 'bound to %{public}s', NetBinder.bound);
    } catch (error) {
      hilog.warn(0x0001, TAG, 'bindBest failed');
    }
  }
}
