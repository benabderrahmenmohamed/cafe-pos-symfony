import js from '@eslint/js';
import prettier from 'eslint-config-prettier';
import reactHooks from 'eslint-plugin-react-hooks';
import { defineConfig, globalIgnores } from 'eslint/config';
import globals from 'globals';
import tseslint from 'typescript-eslint';

const BACKEND_MESSAGE =
  'Reach the backend through ports (useBackend); only src/lib/backend.ts chooses an adapter.';

const adapterImports = {
  group: ['@/adapters/**', '**/adapters/**'],
  message: BACKEND_MESSAGE,
};

/** Backend settings are for the composition root and adapters. */
const envImports = {
  name: '@/lib/env',
  importNames: ['restEnv'],
  message: BACKEND_MESSAGE,
};

// no-restricted-imports only sees static imports: these catch import() and import.meta.glob.
const dynamicBackendImports = [
  { selector: 'ImportExpression[source.value=/adapters/]', message: BACKEND_MESSAGE },
  {
    selector: "MemberExpression[object.type='MetaProperty'][property.name=/^glob/]",
    message: 'import.meta.glob can pull in an adapter: import modules by name.',
  },
];

const networkGlobals = ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource'].map((name) => ({
  name,
  message: BACKEND_MESSAGE,
}));

/** Adapters never import each other; what they share lives in src/lib or src/ports. */
function otherAdapters(...names) {
  return {
    group: names.flatMap((name) => [
      `@/adapters/${name}`,
      `@/adapters/${name}/**`,
      `../${name}`,
      `../${name}/**`,
    ]),
    message: 'Adapters never import each other: share code through src/lib or src/ports.',
  };
}

const DETERMINISTIC_MESSAGE =
  'Domain modules stay deterministic: take the time or a random value as an argument.';

export default defineConfig([
  // .claude/worktrees: other checkouts of this repo (see .prettierignore).
  globalIgnores(['dist', 'coverage', 'api', '.claude/worktrees']),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommendedTypeChecked,
      reactHooks.configs.flat['recommended-latest'],
    ],
    languageOptions: {
      globals: globals.browser,
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
  {
    // UI, ports and shared helpers never depend on a concrete backend.
    files: ['src/**/*.{ts,tsx}'],
    ignores: ['src/adapters/**', 'src/lib/backend.ts'],
    rules: {
      'no-restricted-imports': ['error', { paths: [envImports], patterns: [adapterImports] }],
      'no-restricted-syntax': ['error', ...dynamicBackendImports],
    },
  },
  {
    // Screens, hooks and components make no requests of their own.
    files: [
      'src/app/**/*.{ts,tsx}',
      'src/components/**/*.{ts,tsx}',
      'src/features/**/*.{ts,tsx}',
      'src/routes/**/*.{ts,tsx}',
    ],
    rules: {
      'no-restricted-globals': ['error', ...networkGlobals],
    },
  },
  {
    files: ['src/adapters/memory/**/*.{ts,tsx}'],
    rules: {
      'no-restricted-imports': ['error', { patterns: [otherAdapters('rest')] }],
    },
  },
  {
    // Pure domain modules: no React, no data layer, no backend, no clock, no randomness, no I/O.
    files: ['src/lib/money.ts', 'src/features/caisse/cart.ts'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          paths: [envImports],
          patterns: [
            adapterImports,
            {
              group: [
                'react',
                'react-dom',
                'react-router',
                '@tanstack/*',
                '@/lib/backend',
                '@/lib/backend-context',
                '@/lib/env',
                '@/lib/query',
                '**/lib/backend',
                '**/lib/backend-context',
                '**/lib/env',
                '**/lib/query',
              ],
              message: 'Domain modules stay framework-free so they run and test anywhere.',
            },
          ],
        },
      ],
      'no-restricted-syntax': [
        'error',
        ...dynamicBackendImports,
        { selector: "NewExpression[callee.name='Date']", message: DETERMINISTIC_MESSAGE },
      ],
      'no-restricted-properties': [
        'error',
        { object: 'Date', property: 'now', message: DETERMINISTIC_MESSAGE },
        { object: 'Math', property: 'random', message: DETERMINISTIC_MESSAGE },
        { object: 'crypto', property: 'getRandomValues', message: DETERMINISTIC_MESSAGE },
        { object: 'crypto', property: 'randomUUID', message: DETERMINISTIC_MESSAGE },
      ],
      'no-restricted-globals': [
        'error',
        ...networkGlobals,
        ...['localStorage', 'sessionStorage', 'indexedDB'].map((name) => ({
          name,
          message: 'Domain modules do no I/O.',
        })),
      ],
    },
  },
  {
    files: ['**/*.js'],
    extends: [js.configs.recommended],
    languageOptions: {
      globals: globals.node,
    },
  },
  prettier,
]);
