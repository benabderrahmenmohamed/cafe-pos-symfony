interface ImportMetaEnv {
  readonly VITE_BACKEND?: string;
  /** Where the REST API is, without the /api/v1 prefix; VITE_BACKEND=rest needs it. */
  readonly VITE_API_BASE_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
