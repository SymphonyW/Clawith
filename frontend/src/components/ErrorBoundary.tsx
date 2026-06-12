import React, { Component, ErrorInfo, ReactNode } from 'react';
import { withTranslation, WithTranslation } from 'react-i18next';
import { IconAlertTriangle } from '@tabler/icons-react';

interface Props extends WithTranslation {
    children?: ReactNode;
    fallback?: ReactNode;
}

interface State {
    hasError: boolean;
    error: Error | null;
    componentStack: string;
}

class ErrorBoundary extends Component<Props, State> {
    public state: State = {
        hasError: false,
        error: null,
        componentStack: ''
    };

    public static getDerivedStateFromError(error: Error): State {
        return { hasError: true, error, componentStack: '' };
    }

    public componentDidCatch(error: Error, errorInfo: ErrorInfo) {
        console.error('Uncaught error:', error, errorInfo);
        this.setState({ componentStack: errorInfo.componentStack || '' });

        if (sessionStorage.getItem('clawith_error_recovery_attempted') !== '1') {
            sessionStorage.setItem('clawith_error_recovery_attempted', '1');
            this.clearVolatileClientState();
            window.location.reload();
        }
    }

    private clearVolatileClientState() {
        const preservedKeys = new Set(['token', 'theme', 'i18nextLng']);
        const keysToRemove: string[] = [];

        for (let i = 0; i < localStorage.length; i += 1) {
            const key = localStorage.key(i);
            if (!key) continue;
            if (preservedKeys.has(key)) continue;
            keysToRemove.push(key);
        }

        keysToRemove.forEach(key => localStorage.removeItem(key));
    }

    private resetAndReload = () => {
        localStorage.clear();
        sessionStorage.clear();
        window.location.href = '/login';
    }

    public render() {
        const { t } = this.props;
        if (this.state.hasError) {
            if (this.props.fallback) {
                return this.props.fallback;
            }
            return (
                <div style={{ padding: '20px', color: 'var(--text-primary)', maxWidth: '600px', margin: '40px auto', background: 'var(--bg-card)', borderRadius: '8px', boxShadow: 'var(--shadow-md)' }}>
                    <h2 style={{ display: 'flex', alignItems: 'center', gap: '8px', margin: '0 0 16px 0', color: 'var(--error)' }}>
                        <IconAlertTriangle size={24} stroke={1.8} /> {t('errorBoundary.title')}
                    </h2>
                    <p style={{ color: 'var(--text-secondary)', marginBottom: '16px' }}>
                        {t('errorBoundary.description')}
                    </p>
                    <details style={{ whiteSpace: 'pre-wrap', marginBottom: '20px', padding: '12px', background: 'var(--bg-secondary)', borderRadius: '4px', fontSize: '13px', border: '1px solid var(--border-color)', color: 'var(--error)' }}>
                        <summary style={{ cursor: 'pointer', fontWeight: 'bold', marginBottom: '8px' }}>{t('errorBoundary.errorDetails')}</summary>
                        {this.state.error && this.state.error.toString()}
                        {this.state.error?.stack ? `\n\n${this.state.error.stack}` : ''}
                        {this.state.componentStack ? `\n\nComponent stack:\n${this.state.componentStack}` : ''}
                    </details>
                    <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
                        <button
                            className="btn btn-primary"
                            onClick={() => window.location.reload()}
                        >
                            {t('errorBoundary.refreshPage')}
                        </button>
                        <button
                            className="btn btn-secondary"
                            onClick={this.resetAndReload}
                        >
                            Clear local cache
                        </button>
                    </div>
                </div>
            );
        }

        return this.props.children;
    }
}

export default withTranslation()(ErrorBoundary);
