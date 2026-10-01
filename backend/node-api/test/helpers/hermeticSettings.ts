// V3 LOT 1 : configuration centrale hermétique pour tous les tests — ni variable SOULBAH_*
// de configuration héritée du shell, ni soulbah.config.json local à la racine du dépôt :
// l'exemple versionné (HYBRID, valeurs par défaut) est imposé. Un test qui veut un autre
// mode pose la variable puis appelle resetSettingsCache().
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ENV_KEYS } from "../../src/lib/soulbahSettings";

for (const k of Object.keys(ENV_KEYS)) delete process.env[k];
process.env.SOULBAH_CONFIG = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../../shared/config/soulbah.config.example.json");
