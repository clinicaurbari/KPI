import './globals.css';
import type { Metadata } from 'next';
export const metadata: Metadata = { title: 'Comité Operativo | Clínica Urbarí', description: 'Sistema institucional de seguimiento y control de gestión' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="es"><body>{children}</body></html>; }
