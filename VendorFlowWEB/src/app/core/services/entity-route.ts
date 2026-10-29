// Where a document lives in the app. Used by notifications and the dashboard "needs your attention" list.
export function entityRoute(entityType: string | null | undefined, id: string | null | undefined): string[] {
  if (!entityType) return ['/'];
  const base: Record<string, string> = {
    requisition: '/requisitions', purchase_order: '/purchase-orders', invoice: '/invoices', rfq: '/rfqs',
    goods_receipt: '/goods-receipts', vendor: '/vendors'
  };
  const path = base[entityType];
  return path ? (id ? [path, id] : [path]) : ['/'];
}
