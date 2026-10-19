import type { ReactNode } from "react"

import { SidebarCollapseIcon, SidebarExpandIcon } from "@primer/octicons-react"
import { Tooltip } from "@primer/react-brand"

import { RepositoryNavigationItem } from "@components/repository-navigation-item"
import { RepositoryUserMenu } from "@components/repository-user-menu"

import type { WorkspaceAccountData } from "./types"
import "./styles.css"

function FeedbackIcon({ size = 16 }: { size?: number }) {
  return (
    <svg
      aria-hidden="true"
      focusable="false"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.4"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M8 1.5a6.5 6.5 0 0 0-5.44 10.06L2 14.5l3.08-.8A6.5 6.5 0 1 0 8 1.5Z" />
      <path d="M8 11S5 9.25 5 7.5a1.5 1.5 0 0 1 3-.3 1.5 1.5 0 0 1 3 .3C11 9.25 8 11 8 11Z" />
    </svg>
  )
}

/** Keeps sidebar collapse and real account controls identical across navigation scopes. */
export function WorkspaceNavigation({
  collapsed,
  className,
  data,
  onCollapsedChange,
  children,
  navigationHeader,
  secondaryNavigation,
}: {
  collapsed: boolean
  className?: string
  data: WorkspaceAccountData
  onCollapsedChange: (collapsed: boolean) => void
  children: ReactNode
  navigationHeader?: ReactNode
  secondaryNavigation?: ReactNode
}) {
  const toggleLabel = collapsed ? data.expandNavigationLabel : data.collapseNavigationLabel
  const collapseButton = (
    <RepositoryNavigationItem
      icon={collapsed ? SidebarCollapseIcon : SidebarExpandIcon}
      label={toggleLabel}
      expanded={!collapsed}
      onClick={() => onCollapsedChange(!collapsed)}
    />
  )
  const feedbackLink = (
    <RepositoryNavigationItem
      href="https://gh.io/replica-feedback"
      icon={FeedbackIcon}
      label={data.feedbackLabel}
      external
    />
  )

  return (
    <aside className={`repository-navigation ${className ?? ""}`} data-collapsed={collapsed}>
      {navigationHeader}
      <div className="repository-navigation__sections">
        <div className="repository-navigation__primary">{children}</div>
        {secondaryNavigation ? (
          <div className="repository-navigation__secondary">{secondaryNavigation}</div>
        ) : null}
      </div>
      <div className="repository-navigation__account">
        {collapsed ? (
          <Tooltip text={data.feedbackLabel} type="label" direction="e">
            {feedbackLink}
          </Tooltip>
        ) : (
          feedbackLink
        )}
        {collapsed ? (
          <Tooltip text={toggleLabel} type="label" direction="e">
            {collapseButton}
          </Tooltip>
        ) : (
          collapseButton
        )}
        <RepositoryUserMenu
          accountMenuLabel={data.accountMenuLabel}
          authenticityToken={data.authenticityToken}
          collapsed={collapsed}
          currentUser={data.currentUser}
          darkThemeLabel={data.darkThemeLabel}
          lightThemeLabel={data.lightThemeLabel}
          signOutLabel={data.signOutLabel}
          signOutPath={data.signOutPath}
          systemThemeLabel={data.systemThemeLabel}
        />
      </div>
    </aside>
  )
}
