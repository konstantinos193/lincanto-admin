'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import { AlertCircle, X } from 'lucide-react'
import { AnalyticsHeader } from '@/components/analytics/AnalyticsHeader'
import { AnalyticsMetrics } from '@/components/analytics/AnalyticsMetrics'
import dynamic from 'next/dynamic'

const AnalyticsCharts = dynamic(
  () => import('@/components/analytics/AnalyticsCharts').then((m) => m.AnalyticsCharts),
  {
    ssr: false,
    loading: () => (
      <div className="h-[320px] rounded-2xl bg-slate-800/50 border border-slate-700/50 animate-pulse" />
    ),
  },
)
import { RangeKey, buildPeriod, formatBucketTooltipLabel } from '@/components/analytics/analyticsTheme'
import {
  analyticsApi,
  type AnalyticsMetrics as AnalyticsMetricsData,
  type RevenueChartData,
  type BookingTrendData,
  type UserDistributionData,
  type ActivityData,
} from '@/lib/api/analytics'

function errorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback
}

/** `;` + BOM so Excel in a Greek locale opens the file with columns and accents intact. */
function downloadCsv(filename: string, rows: (string | number)[][]) {
  const body = rows
    .map((row) =>
      row
        .map((cell) => {
          const value = String(cell ?? '')
          return /[";\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value
        })
        .join(';'),
    )
    .join('\r\n')

  const blob = new Blob([`﻿${body}`], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

export default function AnalyticsPage() {
  const [range, setRange] = useState<RangeKey>('30days')
  const period = useMemo(() => buildPeriod(range), [range])

  const [metrics, setMetrics] = useState<AnalyticsMetricsData | null>(null)
  const [revenueData, setRevenueData] = useState<RevenueChartData[]>([])
  const [bookingData, setBookingData] = useState<BookingTrendData[]>([])
  const [userDistribution, setUserDistribution] = useState<UserDistributionData[]>([])
  const [activityData, setActivityData] = useState<ActivityData[]>([])

  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const fetchAll = useCallback(
    async (activePeriod = period, options: { silent?: boolean } = {}) => {
      const { silent = false } = options
      if (silent) setRefreshing(true)
      else setLoading(true)

      try {
        const [metricsRes, revenue, bookings, users, activity] = await Promise.all([
          analyticsApi.getDashboardMetrics(activePeriod),
          analyticsApi.getRevenueChartData(activePeriod),
          analyticsApi.getBookingTrendsData(activePeriod),
          analyticsApi.getUserDistributionData(),
          analyticsApi.getActivityData(activePeriod),
        ])

        setMetrics(metricsRes ?? null)
        setRevenueData(revenue ?? [])
        setBookingData(bookings ?? [])
        setUserDistribution(users ?? [])
        setActivityData(activity ?? [])
        setError(null)
      } catch (err) {
        console.error('Failed to fetch analytics:', err)
        setError(errorMessage(err, 'Αποτυχία φόρτωσης αναλυτικών.'))
      } finally {
        setLoading(false)
        setRefreshing(false)
      }
    },
    [period],
  )

  // Refetch whenever the range changes; the first load is the non-silent one.
  useEffect(() => {
    fetchAll(period, { silent: metrics !== null })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [period])

  const handleExport = () => {
    const label = (value: string) => formatBucketTooltipLabel(value, period.period)

    const rows: (string | number)[][] = [
      ['Αναλυτικά', `${period.startDate} έως ${period.endDate}`],
      [],
      ['Σύνοψη'],
      ['Έσοδα', metrics?.revenue ?? 0],
      ['Κρατήσεις', metrics?.bookings ?? 0],
      ['Ενεργοί χρήστες', metrics?.activeUsers ?? 0],
      [],
      ['Περίοδος', 'Έσοδα', 'Κόστη', 'Καθαρό κέρδος', 'Κρατήσεις', 'Ακυρώσεις', 'Νέοι χρήστες'],
    ]

    revenueData.forEach((row, index) => {
      rows.push([
        label(row.date),
        row.revenue ?? 0,
        row.costs ?? 0,
        row.profit ?? 0,
        bookingData[index]?.bookings ?? 0,
        bookingData[index]?.cancelled ?? 0,
        activityData[index]?.users ?? 0,
      ])
    })

    if (userDistribution.length > 0) {
      rows.push([], ['Κατανομή χρηστών'], ['Κατηγορία', 'Πλήθος', 'Ποσοστό %'])
      userDistribution.forEach((row) => {
        rows.push([row.category, row.count, row.percentage])
      })
    }

    downloadCsv(`analytics-${period.startDate}-${period.endDate}.csv`, rows)
  }

  return (
    <div className="space-y-6">
      <AnalyticsHeader
        range={range}
        onRangeChange={setRange}
        onRefresh={() => fetchAll(period, { silent: true })}
        refreshing={refreshing}
        onExport={handleExport}
        exportDisabled={loading || !metrics}
      />

      {error && (
        <div className="flex items-start gap-3 rounded-xl bg-red-500/10 border border-red-500/30 px-4 py-3">
          <AlertCircle className="h-5 w-5 text-red-400 flex-shrink-0 mt-0.5" />
          <p className="flex-1 text-sm text-red-200">{error}</p>
          <button
            onClick={() => setError(null)}
            aria-label="Κλείσιμο"
            className="text-red-300 hover:text-red-100"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
      )}

      <AnalyticsMetrics metrics={metrics} loading={loading} refreshing={refreshing} />

      <AnalyticsCharts
        period={period}
        revenueData={revenueData}
        bookingData={bookingData}
        userDistribution={userDistribution}
        activityData={activityData}
        loading={loading}
        refreshing={refreshing}
      />
    </div>
  )
}
