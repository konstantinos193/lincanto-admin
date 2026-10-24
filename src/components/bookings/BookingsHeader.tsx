'use client'

import { useEffect, useRef, useState } from 'react'
import { Calendar, Download, FileSpreadsheet, FileText, ChevronDown } from 'lucide-react'
import { bookingsApi } from '@/lib/api/bookings'
import { Booking } from '@/lib/api/types'
import { CreateBookingDialog } from './CreateBookingDialog'

const EXPORT_HEADERS = [
  'ID',
  'Ακίνητο',
  'Δωμάτιο',
  'Επισκέπτης',
  'Email',
  'Τηλέφωνο',
  'Άφιξη',
  'Αναχώρηση',
  'Διανυκτερεύσεις',
  'Επισκέπτες',
  'Σύνολο',
  'Νόμισμα',
  'Κατάσταση',
  'Πληρωμή',
  'Πηγή',
  'Ημ. Δημιουργίας',
]

function nights(checkIn: string, checkOut: string) {
  return Math.ceil((new Date(checkOut).getTime() - new Date(checkIn).getTime()) / 86400000)
}

function buildRows(bookings: Booking[]) {
  return bookings.map(b => [
    b.id,
    b.property?.titleGr || b.propertyId,
    b.roomName || '',
    b.guestName || b.guest?.name || '',
    b.guestEmail || b.guest?.email || '',
    b.guestPhone || b.guest?.phone || '',
    new Date(b.checkIn).toLocaleDateString('el-GR'),
    new Date(b.checkOut).toLocaleDateString('el-GR'),
    nights(b.checkIn, b.checkOut),
    b.guests,
    b.totalPrice,
    b.currency,
    b.status,
    b.paymentStatus,
    b.source || 'DIRECT',
    new Date(b.createdAt).toLocaleDateString('el-GR'),
  ])
}

function exportCSV(bookings: Booking[]) {
  const rows = buildRows(bookings)
  const csvContent = [
    EXPORT_HEADERS.join(','),
    ...rows.map(row =>
      row.map(cell => {
        const str = String(cell ?? '')
        return str.includes(',') || str.includes('"') || str.includes('\n')
          ? `"${str.replace(/"/g, '""')}"`
          : str
      }).join(',')
    ),
  ].join('\n')

  const blob = new Blob(['\uFEFF' + csvContent], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `kratiseis_${new Date().toISOString().slice(0, 10)}.csv`
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

async function exportExcel(bookings: Booking[]) {
  const XLSX = await import('xlsx')
  const rows = buildRows(bookings)
  const ws = XLSX.utils.aoa_to_sheet([EXPORT_HEADERS, ...rows])

  // Column widths
  ws['!cols'] = [
    { wch: 36 }, // ID
    { wch: 28 }, // Ακίνητο
    { wch: 20 }, // Δωμάτιο
    { wch: 22 }, // Επισκέπτης
    { wch: 28 }, // Email
    { wch: 16 }, // Τηλέφωνο
    { wch: 12 }, // Άφιξη
    { wch: 12 }, // Αναχώρηση
    { wch: 14 }, // Διανυκτερεύσεις
    { wch: 12 }, // Επισκέπτες
    { wch: 10 }, // Σύνολο
    { wch: 10 }, // Νόμισμα
    { wch: 16 }, // Κατάσταση
    { wch: 16 }, // Πληρωμή
    { wch: 14 }, // Πηγή
    { wch: 14 }, // Ημ. Δημιουργίας
  ]

  const wb = XLSX.utils.book_new()
  XLSX.utils.book_append_sheet(wb, ws, 'Κρατήσεις')
  XLSX.writeFile(wb, `kratiseis_${new Date().toISOString().slice(0, 10)}.xlsx`)
}

interface BookingsHeaderProps {
  onBookingCreated?: () => void
}

export function BookingsHeader({ onBookingCreated }: BookingsHeaderProps) {
  const [exporting, setExporting] = useState(false)
  const [exportMenuOpen, setExportMenuOpen] = useState(false)
  const [showCreateDialog, setShowCreateDialog] = useState(false)
  const exportMenuRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (exportMenuRef.current && !exportMenuRef.current.contains(e.target as Node)) {
        setExportMenuOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [])

  async function handleExport(format: 'csv' | 'excel') {
    setExportMenuOpen(false)
    setExporting(true)
    try {
      const response = await bookingsApi.exportAll()
      const bookings = response.data?.bookings || []
      if (bookings.length === 0) {
        alert('Δεν υπάρχουν κρατήσεις για εξαγωγή.')
        return
      }
      if (format === 'csv') exportCSV(bookings)
      else await exportExcel(bookings)
    } catch (error: any) {
      console.error('Export error:', error)
      alert(`Αποτυχία εξαγωγής: ${error?.message || 'Άγνωστο σφάλμα'}`)
    } finally {
      setExporting(false)
    }
  }

  const handleBookingCreated = () => {
    onBookingCreated?.()
  }

  return (
    <>
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl sm:text-3xl font-bold text-gray-900">Κρατήσεις</h1>
          <p className="text-gray-600 mt-1 text-sm sm:text-base">Διαχείριση όλων των κρατήσεων και των επιδοτήσεων</p>
        </div>
        <div className="flex items-center gap-2 sm:space-x-3">
          {/* Export dropdown */}
          <div ref={exportMenuRef} className="relative">
            <button
              onClick={() => setExportMenuOpen(!exportMenuOpen)}
              disabled={exporting}
              className="btn btn-secondary flex items-center gap-2 text-sm px-3 py-2"
            >
              <Download className="h-4 w-4" />
              <span className="hidden sm:inline">{exporting ? 'Εξαγωγή...' : 'Εξαγωγή'}</span>
              <ChevronDown className={`h-3.5 w-3.5 transition-transform ${exportMenuOpen ? 'rotate-180' : ''}`} />
            </button>

            {exportMenuOpen && (
              <div className="absolute right-0 top-full mt-2 w-44 bg-[#1e293b] border border-[#334155] rounded-xl shadow-2xl z-50 py-1 overflow-hidden">
                <button
                  onClick={() => handleExport('csv')}
                  className="w-full px-4 py-2.5 text-left flex items-center gap-2.5 hover:bg-slate-700/50 transition-colors text-sm text-slate-300"
                >
                  <FileText className="h-4 w-4 text-slate-400" />
                  CSV
                </button>
                <button
                  onClick={() => handleExport('excel')}
                  className="w-full px-4 py-2.5 text-left flex items-center gap-2.5 hover:bg-slate-700/50 transition-colors text-sm text-slate-300"
                >
                  <FileSpreadsheet className="h-4 w-4 text-green-400" />
                  Excel (.xlsx)
                </button>
              </div>
            )}
          </div>

          <button
            onClick={() => setShowCreateDialog(true)}
            className="btn btn-primary flex items-center gap-2 text-sm px-3 py-2"
          >
            <Calendar className="h-4 w-4" />
            <span className="hidden sm:inline">Νέα Κράτηση</span>
            <span className="sm:hidden">Νέα</span>
          </button>
        </div>
      </div>

      <CreateBookingDialog
        isOpen={showCreateDialog}
        onClose={() => setShowCreateDialog(false)}
        onCreated={handleBookingCreated}
      />
    </>
  )
}

