// Shapes shared by the whole app. Most API answers are used as plain objects, so only the important ones are typed.

export interface PagedResult<T = any> {
  items: T[];
  totalCount: number;
  page: number;
  pageSize: number;
  statusCounts?: any;
  stats?: any;
  counts?: any;
}

export interface AuthUser {
  userId: string;
  tenantId: string;
  email: string;
  fullName: string;
  roles: string[];
  permissions: string[];
}

export interface LoginResponse {
  accessToken: string;
  refreshToken: string;
  expiresAt: string;
  user: AuthUser;
}

export interface Settings {
  appDisplayName: string;
  organizationName: string;
  vendorLabelSingular: string;
  vendorLabelPlural: string;
  logoUrl: string | null;
  currency: string;
  timeZone: string;
  taxSettings: any;
  numbering: any;
  notificationPrefs: any;
  performanceWeights: any;
  invoiceTolerancePct: number;
  allowSelfApproval: boolean;
}

/** One column of the shared data table. */
export interface TableColumn {
  key: string;
  label: string;
  type?: 'text' | 'link' | 'status' | 'money' | 'date' | 'percent' | 'progress' | 'number' | 'priority';
  sortKey?: string;       // API sort column; when set the header is clickable
  align?: 'right';
}
