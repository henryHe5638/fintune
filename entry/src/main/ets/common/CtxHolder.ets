/** UIAbility 上下文持有器，供非 Ability 类（播放模型、菜单等）获取上下文使用。 */
import { common } from '@kit.AbilityKit';

export class CtxHolder {
  static ctx: common.UIAbilityContext | null = null;
}
