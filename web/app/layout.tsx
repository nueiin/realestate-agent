import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Real-Estate Agent',
  description: '공공데이터 기반 부동산 실거래가 분석 에이전트',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="ko">
      <body>{children}</body>
    </html>
  )
}
