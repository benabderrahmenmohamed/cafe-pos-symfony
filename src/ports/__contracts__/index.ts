import { describeAuthPortContract } from './auth.contract';
import { describeCatalogPortContract } from './catalog.contract';
import type { MakeFixture } from './fixture';
import { describeOrdersPortContract } from './orders.contract';
import { describeSalesPortContract } from './sales.contract';
import { describeSessionsPortContract } from './sessions.contract';
import { describeTerminalsPortContract } from './terminals.contract';

export { describeAuthPortContract } from './auth.contract';
export { describeCatalogPortContract } from './catalog.contract';
export { contractBackendIs, requireTestEnv, testEnvOr } from './env';
export { freshTerminalCode } from './fixture';
export type { ContractFixture, MakeFixture } from './fixture';
export { describeOrdersPortContract } from './orders.contract';
export { describeSalesPortContract } from './sales.contract';
export { describeSessionsPortContract } from './sessions.contract';
export { describeTerminalsPortContract } from './terminals.contract';

/**
 * Every port contract against one backend. The database defines the semantics (api/migrations,
 * contracts/errors.md); each adapter runs this suite and must pass it unchanged.
 */
export function describeBackendContract(makeFixture: MakeFixture): void {
  describeAuthPortContract(makeFixture);
  describeCatalogPortContract(makeFixture);
  describeTerminalsPortContract(makeFixture);
  describeSessionsPortContract(makeFixture);
  describeSalesPortContract(makeFixture);
  describeOrdersPortContract(makeFixture);
}
