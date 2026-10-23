import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "资产定帧｜视觉资产管理画布",
  description: "用关系画布管理角色、场景和道具，并将审核结果导回 Excel。",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="zh-CN"><body>{children}</body></html>;
}
