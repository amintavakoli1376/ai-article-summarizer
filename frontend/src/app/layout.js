import './globals.css';

export const metadata = {
  title: 'Article Summarizer',
  description: 'AI article summarizer',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
