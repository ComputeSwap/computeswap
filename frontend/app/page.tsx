// Reads deployments.json on every request, so a redeploy on anvil shows up on the next reload.
import App from "@/components/App";
import type { Deployment } from "@/lib/config";
import { loadDeployment } from "@/lib/server/config";

export const dynamic = "force-dynamic";

export default function Page() {
  let dep: Deployment | null = null;
  try {
    dep = loadDeployment();
  } catch {}
  return <App dep={dep} />;
}
