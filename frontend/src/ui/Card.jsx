export default function Card({ title, desc, right, footer, children, className = "" }) {
  return (
    <div className={`overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm ${className}`.trim()}>
      {(title || desc || right) && (
        <div className="flex items-start justify-between gap-4 border-b border-slate-100 px-5 py-4">
          <div>
            {title && <div className="text-sm font-semibold text-slate-900">{title}</div>}
            {desc && <div className="mt-1 text-xs leading-5 text-slate-500">{desc}</div>}
          </div>
          {right}
        </div>
      )}
      <div className="p-5">{children}</div>
      {footer && <div className="border-t border-slate-100 bg-slate-50 px-5 py-3 text-xs text-slate-500">{footer}</div>}
    </div>
  );
}
