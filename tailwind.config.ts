import type { Config } from 'tailwindcss';
export default { content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'], theme: { extend: { colors: { navy: '#163B65', clinic: '#1E78A8', ink: '#243447' } } }, plugins: [] } satisfies Config;
