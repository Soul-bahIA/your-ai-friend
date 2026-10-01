import { createRoot } from "react-dom/client";
import App from "./App.tsx";
import ConfigError from "./components/ConfigError.tsx";
import { supabaseConfigError } from "./integrations/supabase/client";
import "./index.css";

const root = createRoot(document.getElementById("root")!);
root.render(supabaseConfigError ? <ConfigError message={supabaseConfigError} /> : <App />);
