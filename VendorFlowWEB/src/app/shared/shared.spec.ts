import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { provideRouter } from '@angular/router';
import { StatusBadgeComponent } from './status-badge/status-badge.component';
import { DataTableComponent } from './data-table/data-table.component';
import { ApprovalTimelineComponent } from './approval-timeline/approval-timeline.component';

describe('shared components', () => {
  beforeEach(() => TestBed.configureTestingModule({ providers: [provideHttpClient(), provideRouter([])] }));

  it('status badge shows readable text and a colour', () => {
    const fixture = TestBed.createComponent(StatusBadgeComponent);
    fixture.componentRef.setInput('status', 'PendingApproval');
    fixture.detectChanges();
    const badge = fixture.nativeElement.querySelector('.badge') as HTMLElement;
    expect(badge.textContent?.trim()).toBe('Pending approval');
    expect(badge.className).toContain('amber');
    fixture.componentRef.setInput('status', 'ConvertedToPO');
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('.badge').textContent.trim()).toBe('Converted to PO');
    fixture.componentRef.setInput('status', 'Overdue');
    fixture.detectChanges();
    expect(fixture.nativeElement.querySelector('.badge').className).toContain('red');
  });

  it('data table calculates paging and emits page and sort changes', () => {
    const fixture = TestBed.createComponent(DataTableComponent);
    const table = fixture.componentInstance;
    fixture.componentRef.setInput('columns', [{ key: 'name', label: 'Name', sortKey: 'name' }]);
    fixture.componentRef.setInput('rows', [{ id: '1', name: 'A' }]);
    fixture.componentRef.setInput('totalCount', 84);
    fixture.componentRef.setInput('pageSize', 10);
    fixture.componentRef.setInput('page', 1);
    fixture.detectChanges();
    expect(table.pageCount).toBe(9);
    expect(table.from).toBe(1);
    expect(table.to).toBe(10);
    expect(table.pages).toEqual([1, 2, 3, 4, 5]);

    const pages: number[] = [];
    const sorts: any[] = [];
    table.pageChange.subscribe(p => pages.push(p));
    table.sortChange.subscribe(s => sorts.push(s));
    table.goTo(3);
    table.goTo(1);                // same page: ignored
    table.goTo(99);               // out of range: ignored
    table.sortBy({ key: 'name', label: 'Name', sortKey: 'name' });
    expect(pages).toEqual([3]);
    expect(sorts).toEqual([{ key: 'name', dir: 'asc' }]);
    expect(fixture.nativeElement.textContent).toContain('Showing 1–10 of 84');
  });

  it('data table shows an empty message when there are no rows', () => {
    const fixture = TestBed.createComponent(DataTableComponent);
    fixture.componentRef.setInput('columns', [{ key: 'name', label: 'Name' }]);
    fixture.componentRef.setInput('emptyText', 'No vendors match your filters.');
    fixture.detectChanges();
    expect(fixture.nativeElement.textContent).toContain('No vendors match your filters.');
  });

  it('approval timeline marks done, current and waiting steps', () => {
    const fixture = TestBed.createComponent(ApprovalTimelineComponent);
    const timeline = fixture.componentInstance;
    expect(timeline.state({ status: 'Approved' })).toBe('done');
    expect(timeline.state({ status: 'Pending' })).toBe('current');
    expect(timeline.state({ status: 'Waiting' })).toBe('waiting');
    expect(timeline.state({ status: 'Rejected' })).toBe('bad');
    fixture.componentRef.setInput('steps', [
      { stepNo: 1, name: 'Team Lead', status: 'Approved', decidedByName: 'Mark W.' },
      { stepNo: 2, name: 'Dept Manager', status: 'Pending' }
    ]);
    fixture.detectChanges();
    expect(fixture.nativeElement.textContent).toContain('Team Lead');
    expect(fixture.nativeElement.textContent).toContain('Waiting');
  });
});
