import Link from "next/link"
import { Video, PlaySquare, FolderOpen, BarChart2, Menu , Search } from "lucide-react"
import { Button } from "./ui/button"
import { createClient } from "@/utils/supabase/server"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

export async function HeaderNav() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (user) {
    const navItems = [
      { href: "/pages/upload", label: "Upload", icon: Video },
      { href: "/pages/realtimeStreamPage", label: "Realtime", icon: PlaySquare },
      { href: "/pages/saved-videos", label: "Library", icon: FolderOpen },
      { href: "/pages/search", label: "Search", icon: Search },
      { href: "/pages/statistics", label: "Statistics", icon: BarChart2 },
    ];

    return (
      <>
        {/* Desktop Navigation */}
        <div className="hidden md:flex items-center gap-2">
          {navItems.map((item) => (
            <Button key={item.href} asChild variant="ghost" size="sm" className="text-white/70 hover:text-white hover:bg-white/10 transition-colors">
              <Link href={item.href} className="flex items-center gap-2">
                <item.icon className="h-4 w-4" />
                <span className="hidden lg:inline">{item.label}</span>
              </Link>
            </Button>
          ))}
        </div>

        {/* Mobile Navigation */}
        <div className="flex md:hidden items-center mr-2">
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon" className="text-white/70 hover:text-white hover:bg-white/10">
                <Menu className="h-5 w-5" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" className="w-48 bg-black/90 border-white/10 text-white backdrop-blur-md">
              {navItems.map((item) => (
                <DropdownMenuItem key={item.href} asChild className="focus:bg-white/10 focus:text-white cursor-pointer">
                  <Link href={item.href} className="flex items-center gap-3 w-full py-2 px-2">
                    <item.icon className="h-4 w-4" />
                    <span>{item.label}</span>
                  </Link>
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </>
    )
  }

  return (
    <div className="flex items-center gap-2 sm:gap-6">
      <Button asChild variant="ghost" size="sm" className="text-white/70 hover:text-white hover:bg-white/10 transition-colors">
        <Link href="/#detection">
          <span className="text-xs sm:text-sm">Detection</span>
        </Link>
      </Button>
      <Button asChild variant="ghost" size="sm" className="hidden xs:flex text-white/70 hover:text-white hover:bg-white/10 transition-colors">
        <Link href="https://cal.com/airxashish/30min" target="_blank">
          <span className="text-xs sm:text-sm">Book Demo</span>
        </Link>
      </Button>
      <Button asChild variant="ghost" size="sm" className="text-white/70 hover:text-white hover:bg-white/10 transition-colors">
        <Link href="/#cta">
          <span className="text-xs sm:text-sm">Get Started</span>
        </Link>
      </Button>
    </div>
  )
}
