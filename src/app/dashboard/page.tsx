'use client'

import dynamic from 'next/dynamic'
import { useAuth } from '@/lib/auth/AuthContext'
import { StatsCards } from '@/components/dashboard/StatsCards'

const ChartFallback = () => (
  <div className="h-[300px] rounded-2xl bg-slate-800/50 border border-slate-700/50 animate-pulse" />
)

const RevenueChart = dynamic(
  () => import('@/components/dashboard/RevenueChart').then((m) => m.RevenueChart),
  { ssr: false, loading: ChartFallback },
)
const BookingTrendsChart = dynamic(
  () => import('@/components/dashboard/BookingTrendsChart').then((m) => m.BookingTrendsChart),
  { ssr: false, loading: ChartFallback },
)
import { TodaysActivity } from '@/components/dashboard/TodaysActivity'
import { MaintenanceAlerts } from '@/components/dashboard/MaintenanceAlerts'
import { PaymentStatus } from '@/components/dashboard/PaymentStatus'
import { RecentActivity } from '@/components/dashboard/RecentActivity'
import { TopProperties } from '@/components/dashboard/TopProperties'
import { RecentReviews } from '@/components/dashboard/RecentReviews'
import { RealEstateActions } from '@/components/dashboard/RealEstateActions'
import { HotelActions } from '@/components/dashboard/HotelActions'
import { SystemActions } from '@/components/dashboard/SystemActions'
import { QuickActions } from '@/components/dashboard/QuickActions'

const ROLE_LABELS: Record<string, string> = {
  ADMIN: 'Διαχειριστής',
  MANAGER: 'Διευθυντής',
  PROPERTY_OWNER: 'Ιδιοκτήτης',
  USER: 'Χρήστης',
}

export default function DashboardPage() {
  const { user } = useAuth()

  const today = new Date().toLocaleDateString('el-GR', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })

  const roleLabel = user?.role ? (ROLE_LABELS[user.role] ?? user.role) : null

  return (
    <div className="space-y-8">
      {/* Welcome Banner */}
      <div className="bg-gradient-to-r from-slate-800 to-slate-800/50 border border-slate-700/50 rounded-2xl p-6">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-slate-100">
              Καλώς ήρθατε{user?.name ? `, ${user.name}` : ''}!
            </h1>
            <p className="text-slate-400 mt-1 capitalize">{today}</p>
          </div>
          {roleLabel && (
            <span className="inline-flex items-center px-3 py-1.5 rounded-xl bg-blue-500/15 text-blue-400 text-sm font-semibold w-fit">
              {roleLabel}
            </span>
          )}
        </div>
      </div>

      {/* KPI Stats */}
      <StatsCards />

      {/* Charts Row */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2">
          <RevenueChart />
        </div>
        <BookingTrendsChart />
      </div>

      {/* Operations Row */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <TodaysActivity />
        <MaintenanceAlerts />
        <PaymentStatus />
      </div>

      {/* Data Row */}
      <div className="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <div>
          <h2 className="text-lg font-bold text-slate-100 mb-4">Πρόσφατη Δραστηριότητα</h2>
          <RecentActivity />
        </div>
        <div className="flex flex-col gap-6">
          <TopProperties />
          <RecentReviews />
        </div>
      </div>

      {/* Business Sections */}
      <div className="grid grid-cols-1 xl:grid-cols-2 gap-8">
        <RealEstateActions />
        <HotelActions />
      </div>

      {/* Quick Actions */}
      <QuickActions />

      {/* System / General */}
      <SystemActions />
    </div>
  )
}
